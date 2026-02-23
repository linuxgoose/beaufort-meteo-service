import Foundation

enum RegionGeometry {
    // Region checks used by best_match routing.
    @inlinable static func isInRectangle(lat: Float, lon: Float, latitude: Range<Float>, longitude: Range<Float>) -> Bool {
        latitude.contains(lat) && longitude.contains(lon)
    }

    @inlinable static func isInTriangle(
        lat: Float,
        lon: Float,
        a: (lat: Float, lon: Float),
        b: (lat: Float, lon: Float),
        c: (lat: Float, lon: Float)
    ) -> Bool {
        @inline(__always)
        func cross(
            _ a: (x: Float, y: Float),
            _ b: (x: Float, y: Float),
            _ p: (x: Float, y: Float)
        ) -> Float {
            (p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)
        }

        let p = (x: lon, y: lat)
        let a = (x: a.lon, y: a.lat)
        let b = (x: b.lon, y: b.lat)
        let c = (x: c.lon, y: c.lat)

        let d1 = cross(a, b, p)
        let d2 = cross(b, c, p)
        let d3 = cross(c, a, p)

        let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
        let hasPositive = d1 > 0 || d2 > 0 || d3 > 0

        // Inside or on edge when all signs are consistent.
        return !(hasNegative && hasPositive)
    }

    static func isInCanadaBoundary(lat: Float, lon: Float) -> Bool {
        guard let boundary = canadaBoundary else {
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

    /// Canada check for model routing.
    /// Uses exact boundary polygon as the authoritative check.
    static func isInCanada(lat: Float, lon: Float) -> Bool {
        // Exact boundary check (handles all valid Canadian points including coast/islands)
        if isInCanadaBoundary(lat: lat, lon: lon) {
            return true
        }
    }

    private static let canadaBoundary: CanadaBoundary? = loadCanadaBoundary()

    private static func loadCanadaBoundary() -> CanadaBoundary? {
          guard let url = Bundle.module.url(forResource: "canada", withExtension: "geojson", subdirectory: "Regions"),
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

        return CanadaBoundary(
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

    private static func isInRing(point: (x: Double, y: Double), edges: [Edge]) -> Bool {
        guard !edges.isEmpty else {
            return false
        }

        var intersects = false

        for edge in edges {
            if point.y <= edge.yMin || point.y > edge.yMax {
                continue
            }

            let intersectionX = edge.xAtYMin + (point.y - edge.yMin) * edge.invDy
            if point.x < intersectionX {
                intersects.toggle()
            }
        }

        return intersects
    }

    private struct CanadaBoundary {
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
