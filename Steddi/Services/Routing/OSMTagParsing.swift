import Foundation

/// Shared, pure OSM tag interpretation used by every consumer of Overpass data.
///
/// `parseMaxspeed` / `defaultSpeedMph` were promoted out of `OSMSpeedLimitService`
/// so the road-graph loader and the speed-limit service derive identical speeds
/// from identical tags. Everything here is a stateless pure function over raw
/// tag strings — it unit-tests like `RouteGeometry`, with no I/O and no state.
enum OSMTagParsing {

    // MARK: Constants

    /// Conversion factor from km/h to mph. OSM bare `maxspeed` values are km/h.
    static let mphPerKmh = 0.621371
    /// Conversion factor from mph to m/s (router cost is in metric seconds).
    static let mpsPerMph = 0.44704

    // MARK: - Speed

    /// Parse an OSM `maxspeed` tag value to mph.
    ///
    /// "NN mph" -> NN. Bare "NN" is km/h per OSM convention. Non-numeric values
    /// ("none", "signals", "walk", garbage) return nil. Multi-value lists
    /// ("30 mph;45 mph") return nil so the caller falls back to a class default.
    static func parseMaxspeed(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }

        let value: Double?
        if raw.hasSuffix("mph") {
            value = Double(raw.dropLast(3).trimmingCharacters(in: .whitespaces))
        } else if raw.hasSuffix("km/h") {
            value = Double(raw.dropLast(4).trimmingCharacters(in: .whitespaces)).map { $0 * mphPerKmh }
        } else {
            value = Double(raw).map { $0 * mphPerKmh }
        }

        guard let value, value > 0 else { return nil }
        return value
    }

    /// Typical US speed limit (mph) for an OSM highway class, used when no
    /// usable `maxspeed` tag exists. `*_link` ramps default to 35.
    static func defaultSpeedMph(forHighwayClass highway: String) -> Double? {
        if highway.hasSuffix("_link") { return 35 }
        switch highway {
        case "motorway": return 65
        case "trunk": return 55
        case "primary": return 45
        case "secondary": return 40
        case "tertiary": return 35
        case "unclassified": return 35
        case "residential": return 25
        case "living_street": return 10
        case "service": return 15
        default: return nil
        }
    }

    /// Free-flow speed in m/s from a way's `maxspeed`/`highway` tags. Falls back
    /// to the class default when `maxspeed` is absent/unparseable. nil only when
    /// the highway class itself is unknown (a way that should be filtered out).
    static func freeFlowSpeedMPS(maxspeed: String?, highway: String) -> Double? {
        let mph = parseMaxspeed(maxspeed) ?? defaultSpeedMph(forHighwayClass: highway)
        guard let mph else { return nil }
        return mph * mpsPerMph
    }

    // MARK: - Direction

    /// How a way is traversable. `roundabout` and `motorway` imply forward-only
    /// per OSM defaults even without an explicit `oneway` tag.
    enum OnewayDirection: Sendable, Equatable {
        case forward      // travel only in node order
        case reverse      // travel only against node order
        case both         // bidirectional

        var allowsForward: Bool { self != .reverse }
        var allowsReverse: Bool { self != .forward }
    }

    /// Resolve directionality from `oneway` plus the OSM implicit-oneway defaults
    /// (`junction=roundabout` and `highway=motorway` are forward-only unless an
    /// explicit `oneway` overrides them).
    static func parseOneway(
        oneway: String?,
        junction: String? = nil,
        highway: String? = nil
    ) -> OnewayDirection {
        let value = oneway?.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "yes", "true", "1":
            return .forward
        case "-1", "reverse":
            return .reverse
        case "no", "false", "0":
            return .both
        default:
            // No explicit oneway: apply OSM implicit defaults.
            let junctionValue = junction?.trimmingCharacters(in: .whitespaces).lowercased()
            if junctionValue == "roundabout" || junctionValue == "circular" {
                return .forward
            }
            if highway?.trimmingCharacters(in: .whitespaces).lowercased() == "motorway" {
                return .forward
            }
            return .both
        }
    }

    // MARK: - Access

    /// Vehicle access classification derived from `access` / `motor_vehicle` /
    /// `vehicle` tags.
    enum AccessLevel: Sendable, Equatable {
        case allowed         // default
        case destinationOnly // access=destination — usable only if it holds an endpoint
        case restricted      // private / no — hard-excluded from the driving profile
    }

    /// Resolve access for the driving profile. `motor_vehicle`/`vehicle` take
    /// precedence over the generic `access` tag (OSM mode hierarchy). `customers`
    /// is treated like `destination` (usable only at an endpoint).
    static func parseAccess(
        access: String?,
        motorVehicle: String? = nil,
        vehicle: String? = nil
    ) -> AccessLevel {
        // Most specific mode wins.
        for raw in [motorVehicle, vehicle, access] {
            guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { continue }
            switch value {
            case "no", "private":
                return .restricted
            case "destination", "customers", "delivery", "permit":
                return .destinationOnly
            case "yes", "permissive", "designated", "destination_only":
                // destination_only is a rare alias; treat permissive as allowed.
                return value == "destination_only" ? .destinationOnly : .allowed
            default:
                continue
            }
        }
        return .allowed
    }

    // MARK: - Turn lanes

    /// A single lane's permitted turn directions, parsed from one `turn:lanes`
    /// pipe-delimited cell (e.g. "left;through"). An empty cell ("none"/"") means
    /// no restriction (through allowed).
    struct LaneTurns: Sendable, Equatable {
        let left: Bool
        let through: Bool
        let right: Bool
        /// The lane permits a U-turn (`reverse`). A U-turn lane is NOT a left-turn
        /// pocket — conflating the two wrongly signals a protected-left phase to
        /// the cost model, so it carries its own flag.
        var uTurn: Bool = false
        /// A lane that permits left and nothing else is a dedicated left pocket.
        /// A reverse/U-turn permission does not count — a `left;reverse` lane is a
        /// shared left+U-turn pocket, but a `reverse`-only lane is not a left.
        var isDedicatedLeft: Bool { left && !through && !right && !uTurn }
        var isDedicatedRight: Bool { right && !through && !left && !uTurn }
    }

    /// Parse an OSM `turn:lanes` value (e.g. "left|through|through;right") into
    /// per-lane turn permissions, left-to-right. Returns an empty array for a
    /// missing/empty tag. "none"/"" is an unrestricted (through) lane.
    ///
    /// Token mapping:
    /// - `left`/`slight_left`/`sharp_left` → left; same for the right family.
    /// - `through` → through.
    /// - `reverse` → a U-turn lane (`uTurn`), NOT a left pocket. A `reverse`-only
    ///   lane must not read as a dedicated left, or the cost model wrongly bills it
    ///   a protected-left phase.
    /// - `merge_to_left`/`merge_to_right` → through. These are NOT turns: the lane
    ///   is ending and traffic must shift into the adjacent (left/right) lane while
    ///   continuing straight. The `_to_left`/`_to_right` names the *adjacent lane to
    ///   move into*, not a turn direction, so neither sets a turn flag. (The old
    ///   code mapped them to a turn — and, because the substrings "left"/"right"
    ///   also matched, set both flags at once — which was dead, contradictory
    ///   disambiguation.)
    static func parseTurnLanes(_ raw: String?) -> [LaneTurns] {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return [] }
        return raw.split(separator: "|", omittingEmptySubsequences: false).map { cell in
            let tokens = cell
                .lowercased()
                .split(whereSeparator: { $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "none" }

            if tokens.isEmpty {
                // Unmarked lane: through movement permitted.
                return LaneTurns(left: false, through: true, right: false)
            }

            var left = false, through = false, right = false, uTurn = false
            for token in tokens {
                // Match the exact special tokens first so their substrings
                // ("left"/"right") don't leak into the cardinal-turn checks below.
                if token == "reverse" {
                    uTurn = true
                } else if token == "merge_to_left" || token == "merge_to_right" {
                    // Lane ends; driver continues straight while changing lanes.
                    through = true
                } else {
                    if token.contains("left") { left = true }
                    if token.contains("right") { right = true }
                    if token.contains("through") { through = true }
                }
            }
            return LaneTurns(left: left, through: through, right: right, uTurn: uTurn)
        }
    }

    /// Estimate the count of oncoming lanes a driver must cross for an unprotected
    /// left, from `lanes`/`lanes:forward`/`oneway`. For a two-way road, oncoming ≈
    /// half the total lanes (min 1). A oneway road has zero oncoming. Used by the
    /// Phase-4 cost model; lives here so all lane reasoning is in one place.
    static func oncomingLaneCount(
        lanes: String?,
        lanesForward: String? = nil,
        oneway: OnewayDirection
    ) -> Int {
        if oneway != .both { return 0 }
        if let forward = lanesForward.flatMap(Int.init), let total = lanes.flatMap(Int.init), total > forward {
            return max(1, total - forward)
        }
        if let total = lanes.flatMap(Int.init), total > 0 {
            return max(1, total / 2)
        }
        // No lane data: assume one oncoming lane (conservative single carriageway).
        return 1
    }

    // MARK: - Road class

    /// Coarse routable road classification packed into a single byte for the
    /// CSR edge record. `unknown` is the filter sentinel — a way whose `highway`
    /// maps to `unknown` is not part of the driving graph.
    enum RoadClass: UInt8, Comparable, Sendable, Codable {
        case motorway = 0
        case trunk = 1
        case primary = 2
        case secondary = 3
        case tertiary = 4
        case unclassified = 5
        case residential = 6
        case livingStreet = 7
        case service = 8
        case link = 9
        case unknown = 255

        static func < (lhs: RoadClass, rhs: RoadClass) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Map an OSM `highway` value to a `RoadClass`. All `*_link` ramps collapse to
    /// `.link`. Non-drivable classes (footway/path/cycleway/steps/track/pedestrian)
    /// return `.unknown` so the loader drops them from the driving profile.
    static func parseRoadClass(_ highway: String?) -> RoadClass {
        guard let highway = highway?.trimmingCharacters(in: .whitespaces).lowercased(), !highway.isEmpty else {
            return .unknown
        }
        if highway.hasSuffix("_link") { return .link }
        switch highway {
        case "motorway": return .motorway
        case "trunk": return .trunk
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .tertiary
        case "unclassified": return .unclassified
        case "residential": return .residential
        case "living_street": return .livingStreet
        case "service": return .service
        default: return .unknown
        }
    }

    // MARK: - Boolean tags

    /// Interpret an OSM yes/no-style boolean tag. "yes"/"true"/"1" -> true;
    /// everything else (including nil and "no") -> false. A `tunnel`/`bridge`
    /// value other than "no" (e.g. "culvert", "viaduct", "yes") counts as present.
    static func parseBoolTag(_ raw: String?, presentIfNonNo: Bool = false) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !value.isEmpty else { return false }
        if presentIfNonNo { return value != "no" && value != "false" && value != "0" }
        return value == "yes" || value == "true" || value == "1"
    }
}
