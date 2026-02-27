import Foundation

enum RegionGeometry {
    struct Point {
        let lat: Float
        let lon: Float
    }

    struct Triangle {
        let a: Point
        let b: Point
        let c: Point

        @inlinable
        func contains(lat: Float, lon: Float) -> Bool {
            @inline(__always)
            func cross(_ a: Point, _ b: Point, _ p: Point) -> Float {
                (p.lon - a.lon) * (b.lat - a.lat) - (p.lat - a.lat) * (b.lon - a.lon)
            }

            let p = Point(lat: lat, lon: lon)
            let d1 = cross(a, b, p)
            let d2 = cross(b, c, p)
            let d3 = cross(c, a, p)

            let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
            let hasPositive = d1 > 0 || d2 > 0 || d3 > 0

            return !(hasNegative && hasPositive)
        }
    }

    // Region checks used by best_match routing.
    @inlinable static func isInRectangle(lat: Float, lon: Float, latitude: Range<Float>, longitude: Range<Float>) -> Bool {
        latitude.contains(lat) && longitude.contains(lon)
    }
    
    static func isInUKVArea(lat: Float, lon: Float) -> Bool {
        let isInUkRectangle = RegionGeometry.isInRectangle(lat: lat, lon: lon, latitude: 49.9..<61, longitude: -11..<1.8)
        let channelTriangle = Triangle(
            a: Point(lat: 49.9, lon: -0.2),
            b: Point(lat: 49.9, lon: 1.8),
            c: Point(lat: 51.1, lon: 1.8)
        )
        let isInChannelCutOutTriangle = channelTriangle.contains(lat: lat, lon: lon)
        return isInUkRectangle && !isInChannelCutOutTriangle
    }

    /// Canada check for model routing.
    /// Uses exact boundary polygon as the authoritative check.
    static func isInCanadaBoundary(lat: Float, lon: Float) -> Bool {
        return isInBoundary(lat: lat, lon: lon, boundary: canadaBoundary)
    }

    private static let canadaBoundary: Boundary? = loadBoundary(named: "canada-simplified")

    /// Shared boundary check used by region-specific wrappers.
    private static func isInBoundary(lat: Float, lon: Float, boundary: Boundary?) -> Bool {
        guard let boundary = boundary else {
            return false
        }

        let point = (x: Double(lon), y: Double(lat))
        guard boundary.boundingBox.longitude.contains(point.x), boundary.boundingBox.latitude.contains(point.y) else {
            return false
        }

        for polygon in boundary.polygons {
            if isInPolygon(point: point, polygon: polygon) {
                return true
            }
        }
        return false
    }

    /// Load a GeoJSON boundary from Resources/Regions/<name>.geojson
    private static func loadBoundary(named resourceName: String) -> Boundary? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "geojson", subdirectory: "Regions"),
              let data = try? Data(contentsOf: url),
              let featureCollection = try? JSONDecoder().decode(GeoJSONFeatureCollection.self, from: data),
              let geometry = featureCollection.features.first?.geometry,
              ["multipolygon", "polygon"].contains(geometry.type.lowercased()) else {
            return nil
        }

        let polygonsCoordinates = geometry.coordinates.asMultiPolygon()
        let polygons = polygonsCoordinates.compactMap { polygon -> Polygon? in
            let rings = polygon.map { buildEdges(ring: $0) }.filter { !$0.isEmpty }
            guard let outer = rings.first else {
                return nil
            }
            return Polygon(outer: outer, holes: Array(rings.dropFirst()))
        }

        let allPoints = polygonsCoordinates.flatMap { $0 }.flatMap { $0 }
        guard let minX = allPoints.map({ $0[0] }).min(),
              let maxX = allPoints.map({ $0[0] }).max(),
              let minY = allPoints.map({ $0[1] }).min(),
              let maxY = allPoints.map({ $0[1] }).max() else {
            return nil
        }

        return Boundary(
            polygons: polygons,
            boundingBox: (latitude: minY...maxY, longitude: minX...maxX)
        )
    }

    private static func buildEdges(ring: [[Double]]) -> [Edge] {
        guard ring.count >= 3 else {
            return []
        }

        var edges: [Edge] = []
        var previous = ring[ring.count - 1]

        for current in ring {
            let x1 = previous[0]
            let y1 = previous[1]
            let x2 = current[0]
            let y2 = current[1]

            if y1 == y2 {
                previous = current
                continue
            }

            let yMin = min(y1, y2)
            let yMax = max(y1, y2)
            let xAtYMin = y1 < y2 ? x1 : x2
            let invDy = (x2 - x1) / (y2 - y1)

            edges.append(Edge(yMin: yMin, yMax: yMax, xAtYMin: xAtYMin, invDy: invDy))
            previous = current
        }

        return edges
    }

    private static func isInPolygon(point: (x: Double, y: Double), polygon: Polygon) -> Bool {
        guard isInRing(point: point, edges: polygon.outer) else {
            return false
        }

        if polygon.holes.isEmpty {
            return true
        }

        for hole in polygon.holes {
            if isInRing(point: point, edges: hole) {
                return false
            }
        }
        return true
    }

    @inline(__always)
    private static func isInRing(point: (x: Double, y: Double), edges: [Edge]) -> Bool {
        guard !edges.isEmpty else {
            return false
        }

        var intersects = false
        let py = point.y
        let px = point.x

        for edge in edges {
            // Fast rejection: horizontal ray sweep only crosses edges in this y-range
            if py <= edge.yMin || py > edge.yMax {
                continue
            }

            // Single multiply-add for x-intersection: x = xAtYMin + (py - yMin) * invDy
            let isectX = edge.xAtYMin + (py - edge.yMin) * edge.invDy
            
            // Toggle on each crossing to the right of point
            if px < isectX {
                intersects.toggle()
            }
        }

        return intersects
    }

    private struct Boundary {
        let polygons: [Polygon]
        let boundingBox: (latitude: ClosedRange<Double>, longitude: ClosedRange<Double>)
    }

    private struct Polygon {
        let outer: [Edge]
        let holes: [[Edge]]
    }

    private struct Edge {
        let yMin: Double
        let yMax: Double
        let xAtYMin: Double
        let invDy: Double
    }

    private struct GeoJSONFeatureCollection: Decodable {
        let features: [GeoJSONFeature]
    }

    private struct GeoJSONFeature: Decodable {
        let geometry: GeoJSONGeometry
    }

    private struct GeoJSONGeometry: Decodable {
        let type: String
        let coordinates: GeometryCoordinates

        enum GeometryCoordinates {
            case polygon([[[Double]]])
            case multipolygon([[[[Double]]]])

            func asMultiPolygon() -> [[[[Double]]]] {
                switch self {
                case .polygon(let polygon):
                    return [polygon]
                case .multipolygon(let multipolygon):
                    return multipolygon
                }
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case coordinates
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            let geometryType = type.lowercased()
            if geometryType == "polygon" {
                let polygon = try container.decode([[[Double]]].self, forKey: .coordinates)
                coordinates = .polygon(polygon)
            } else {
                let multipolygon = try container.decode([[[[Double]]]].self, forKey: .coordinates)
                coordinates = .multipolygon(multipolygon)
            }
        }
    }
}