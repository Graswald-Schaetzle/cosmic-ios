import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

struct CaptureValidationIssue: Hashable, Sendable {
    let code: String
    let message: String
}

struct CaptureValidationResult: Sendable {
    let issues: [CaptureValidationIssue]

    var isValid: Bool { issues.isEmpty }
}

/// On-device mirror of the Echo-3 capture contract. `tools/validate-bundle`
/// runs the same checks on a desktop (plus the ZIP rules); keep the two in sync.
enum CaptureBundleValidator {
    private static let orthonormalTolerance = 1e-4
    private static let finalRowTolerance = 1e-6
    private static let minFocal = 100.0
    private static let maxFocal = 10_000.0
    private static let maxIssuesPerCode = 5

    static func validateBundle(at root: URL, frameCount: Int) -> CaptureValidationResult {
        var issues: [CaptureValidationIssue] = []
        let imagesDir = root.appendingPathComponent("images", isDirectory: true)
        let camerasDir = root.appendingPathComponent("cameras", isDirectory: true)

        let imageNames = ((try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") }
            .sorted()

        issues.append(contentsOf: validateFrameCount(frameCount))
        issues.append(contentsOf: validateImageFilenames(imageNames, expectedCount: frameCount))
        issues.append(
            contentsOf: validateCameraFile(
                camerasDir.appendingPathComponent("camera_trajectory.json"),
                missingCode: "TRAJECTORY_MISSING"
            ) { validateTrajectory($0, expectedCount: frameCount) }
        )
        issues.append(
            contentsOf: validateCameraFile(
                camerasDir.appendingPathComponent("per_frame_intrinsics.json"),
                missingCode: "PER_FRAME_INTRINSICS_MISSING"
            ) { validatePerFrameIntrinsics($0, expectedCount: frameCount) }
        )
        issues.append(
            contentsOf: validateImages(
                imageNames.prefix(frameCount).map { imagesDir.appendingPathComponent($0) }
            )
        )
        return CaptureValidationResult(issues: issues)
    }

    static func validateFrameCount(_ frameCount: Int) -> [CaptureValidationIssue] {
        if frameCount < 1 {
            return [CaptureValidationIssue(code: "IMAGES_MISSING", message: "Bundle has no images")]
        }
        if frameCount > CapturePaths.maxFrames {
            return [
                CaptureValidationIssue(
                    code: "TOO_MANY_FRAMES",
                    message: "Bundle has \(frameCount) images; the limit is \(CapturePaths.maxFrames)"
                ),
            ]
        }
        return []
    }

    private static func validateCameraFile(
        _ url: URL,
        missingCode: String,
        validate: (Any) -> [CaptureValidationIssue]
    ) -> [CaptureValidationIssue] {
        let name = "cameras/\(url.lastPathComponent)"
        guard let data = try? Data(contentsOf: url) else {
            return [CaptureValidationIssue(code: missingCode, message: "Bundle is missing \(name)")]
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return [
                CaptureValidationIssue(
                    code: "CAMERA_FILE_INVALID_JSON",
                    message: "\(name) is not valid JSON"
                ),
            ]
        }
        return validate(json)
    }

    static func validateImageFilenames(_ names: [String], expectedCount: Int) -> [CaptureValidationIssue] {
        var issues: [CaptureValidationIssue] = []
        let sorted = names.sorted()

        if sorted.count != expectedCount {
            issues.append(
                CaptureValidationIssue(
                    code: "IMAGE_COUNT_MISMATCH",
                    message: "Found \(sorted.count) images but expected \(expectedCount)"
                )
            )
        }

        guard expectedCount > 0 else { return issues }

        for index in 1...expectedCount {
            let expected = CapturePaths.imageFilename(index: index)
            let actualIndex = index - 1
            if actualIndex >= sorted.count {
                issues.append(
                    CaptureValidationIssue(
                        code: "IMAGE_SEQUENCE_GAP",
                        message: "Missing \(expected)"
                    )
                )
                break
            }
            let actual = sorted[actualIndex]
            if actual != expected {
                if index == 1 {
                    issues.append(
                        CaptureValidationIssue(
                            code: "IMAGE_SEQUENCE_START",
                            message: "Images must start at Image_000001.jpg, found \(actual)"
                        )
                    )
                } else {
                    issues.append(
                        CaptureValidationIssue(
                            code: "IMAGE_SEQUENCE_GAP",
                            message: "Expected \(expected), found \(actual)"
                        )
                    )
                }
                break
            }
        }

        return issues
    }

    static func validateTrajectory(_ json: Any, expectedCount: Int) -> [CaptureValidationIssue] {
        var issues: [CaptureValidationIssue] = []
        guard let matrices = json as? [Any] else {
            return [
                CaptureValidationIssue(
                    code: "TRAJECTORY_NOT_ARRAY",
                    message: "cameras/camera_trajectory.json must be an array of 4x4 matrices"
                ),
            ]
        }

        if matrices.count != expectedCount {
            issues.append(
                CaptureValidationIssue(
                    code: "TRAJECTORY_COUNT_MISMATCH",
                    message: "Trajectory has \(matrices.count) matrices but expected \(expectedCount)"
                )
            )
        }

        for (index, matrix) in matrices.enumerated() {
            issues.append(contentsOf: validateMatrix(matrix, index: index))
            if issues.count > 10 {
                issues.append(
                    CaptureValidationIssue(
                        code: "VALIDATION_TRUNCATED",
                        message: "Too many errors, validation truncated"
                    )
                )
                break
            }
        }
        return issues
    }

    /// `per_frame_intrinsics.json`: `frame_count` = N, the encoded JPEG size,
    /// and four arrays of N finite values inside the contract bounds.
    static func validatePerFrameIntrinsics(
        _ json: Any,
        expectedCount: Int
    ) -> [CaptureValidationIssue] {
        guard let object = json as? [String: Any] else {
            return [
                CaptureValidationIssue(
                    code: "PER_FRAME_INTRINSICS_INVALID",
                    message: "cameras/per_frame_intrinsics.json must be an object"
                ),
            ]
        }
        var issues: [CaptureValidationIssue] = []
        if number(object["frame_count"]) != Double(expectedCount) {
            issues.append(
                CaptureValidationIssue(
                    code: "PER_FRAME_INTRINSICS_COUNT_MISMATCH",
                    message: "frame_count must be \(expectedCount)"
                )
            )
        }
        let width = number(object["width_px"])
        let height = number(object["height_px"])
        if width != Double(CapturePaths.requiredWidth) || height != Double(CapturePaths.requiredHeight) {
            issues.append(
                CaptureValidationIssue(
                    code: "PER_FRAME_INTRINSICS_RESOLUTION_MISMATCH",
                    message: "width_px × height_px must be 1920×1440"
                )
            )
        }
        let fields = ["fx_px", "fy_px", "cx_px", "cy_px"]
        let arrays = fields.map { (object[$0] as? [Any])?.map(number) }
        for (field, values) in zip(fields, arrays) where values?.count != expectedCount {
            issues.append(
                CaptureValidationIssue(
                    code: "PER_FRAME_INTRINSICS_ARRAY_LENGTH",
                    message: "per_frame_intrinsics.json.\(field) must contain \(expectedCount) values"
                )
            )
        }
        guard issues.isEmpty, let width, let height else { return issues }
        let columns = arrays.map { $0 ?? [] }
        return validatePerFrameValues(columns, width: width, height: height)
    }

    private static func validatePerFrameValues(
        _ columns: [[Double?]],
        width: Double,
        height: Double
    ) -> [CaptureValidationIssue] {
        var issues = CappedIssues(limit: maxIssuesPerCode)
        for index in 0..<columns[0].count {
            let entry = "per_frame_intrinsics.json[\(index)]"
            guard let fx = columns[0][index], let fy = columns[1][index],
                  let cx = columns[2][index], let cy = columns[3][index]
            else {
                issues.append(code: "INTRINSICS_INVALID_VALUE", message: "\(entry): values must be finite numbers")
                continue
            }
            if !(minFocal...maxFocal).contains(fx) {
                issues.append(code: "INTRINSICS_FX_UNREASONABLE", message: "\(entry): fx_px must be 100...10000")
            }
            if !(minFocal...maxFocal).contains(fy) {
                issues.append(code: "INTRINSICS_FY_UNREASONABLE", message: "\(entry): fy_px must be 100...10000")
            }
            if !(cx > 0 && cx < width) {
                issues.append(code: "INTRINSICS_CX_OUT_OF_BOUNDS", message: "\(entry): cx_px must be inside (0, width)")
            }
            if !(cy > 0 && cy < height) {
                issues.append(code: "INTRINSICS_CY_OUT_OF_BOUNDS", message: "\(entry): cy_px must be inside (0, height)")
            }
        }
        return issues.list
    }

    /// Pixel size, EXIF Orientation and EXIF capture time of every image, in
    /// frame order. Capture times must be complete and strictly increasing.
    static func validateImages(_ urls: [URL]) -> [CaptureValidationIssue] {
        var issues = CappedIssues(limit: maxIssuesPerCode)
        var previous: (name: String, seconds: Double)?
        for url in urls {
            let name = "images/\(url.lastPathComponent)"
            guard let properties = imageProperties(at: url),
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else {
                issues.append(code: "IMAGE_UNREADABLE", message: "\(name) is not a readable JPEG")
                continue
            }
            if width != CapturePaths.requiredWidth || height != CapturePaths.requiredHeight {
                issues.append(code: "IMAGE_SIZE_MISMATCH", message: "\(name) is \(width)×\(height), expected 1920×1440")
            }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
                issues.append(code: "EXIF_ORIENTATION_NOT_IDENTITY", message: "\(name) EXIF Orientation is \(orientation); it must be absent or 1")
            }
            guard let seconds = captureTimeSeconds(properties) else {
                let code = properties[kCGImagePropertyExifDictionary] == nil
                    ? "EXIF_MISSING" : "EXIF_CAPTURE_TIME_INVALID"
                issues.append(code: code, message: "\(name) needs DateTimeOriginal, SubSecTimeOriginal, and OffsetTimeOriginal")
                continue
            }
            if let previous, seconds <= previous.seconds {
                issues.append(code: "EXIF_TIMESTAMPS_NOT_INCREASING", message: "\(name) EXIF time is not after \(previous.name)")
            }
            previous = (name, seconds)
        }
        return issues.list
    }

    private static func imageProperties(at url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private static func captureTimeSeconds(_ properties: [CFString: Any]) -> Double? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return nil
        }
        return CaptureExifTime.seconds(
            dateTimeOriginal: exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            subSecTimeOriginal: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
            offsetTimeOriginal: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        )
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite
        else {
            return nil
        }
        return value.doubleValue
    }

    static func validateMatrix(_ matrix: Any, index: Int) -> [CaptureValidationIssue] {
        var issues: [CaptureValidationIssue] = []
        let prefix = "Matrix[\(index)]"

        guard let rows = matrix as? [[Any]], rows.count == 4,
              rows.allSatisfy({ $0.count == 4 })
        else {
            return [
                CaptureValidationIssue(
                    code: "MATRIX_SHAPE",
                    message: "\(prefix): Expected 4x4 matrix"
                ),
            ]
        }

        var values = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        for r in 0..<4 {
            for c in 0..<4 {
                guard let number = rows[r][c] as? Double ?? (rows[r][c] as? NSNumber)?.doubleValue,
                      number.isFinite
                else {
                    issues.append(
                        CaptureValidationIssue(
                            code: "MATRIX_NON_FINITE",
                            message: "\(prefix)[\(r)][\(c)]: Value must be finite"
                        )
                    )
                    return issues
                }
                values[r][c] = number
            }
        }

        let rotation = [
            [values[0][0], values[0][1], values[0][2]],
            [values[1][0], values[1][1], values[1][2]],
            [values[2][0], values[2][1], values[2][2]],
        ]
        let det = determinant3x3(rotation)
        if abs(det) < 1e-10 {
            issues.append(
                CaptureValidationIssue(
                    code: "MATRIX_SINGULAR",
                    message: "\(prefix): Matrix is singular"
                )
            )
            return issues
        }

        let col0 = [values[0][0], values[1][0], values[2][0]]
        let col1 = [values[0][1], values[1][1], values[2][1]]
        let col2 = [values[0][2], values[1][2], values[2][2]]
        let norms = [norm3(col0), norm3(col1), norm3(col2)]
        if norms.contains(where: { abs($0 - 1) > orthonormalTolerance }) {
            issues.append(
                CaptureValidationIssue(
                    code: "ROTATION_NOT_UNIT",
                    message: "\(prefix): Rotation columns not unit vectors"
                )
            )
        }

        let dots = [abs(dot3(col0, col1)), abs(dot3(col0, col2)), abs(dot3(col1, col2))]
        if dots.contains(where: { $0 > orthonormalTolerance }) {
            issues.append(
                CaptureValidationIssue(
                    code: "ROTATION_NOT_ORTHOGONAL",
                    message: "\(prefix): Rotation columns not orthogonal"
                )
            )
        }

        if abs(det - 1) > orthonormalTolerance {
            issues.append(
                CaptureValidationIssue(
                    code: "ROTATION_IMPROPER",
                    message: "\(prefix): Rotation determinant not +1"
                )
            )
        }

        let finalRow = values[3]
        if abs(finalRow[0]) > finalRowTolerance
            || abs(finalRow[1]) > finalRowTolerance
            || abs(finalRow[2]) > finalRowTolerance
            || abs(finalRow[3] - 1) > finalRowTolerance
        {
            issues.append(
                CaptureValidationIssue(
                    code: "MATRIX_FINAL_ROW",
                    message: "\(prefix): Final row must be [0, 0, 0, 1]"
                )
            )
        }

        return issues
    }

    static func jpegPixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let properties = imageProperties(at: url),
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }

    private static func determinant3x3(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    private static func dot3(_ a: [Double], _ b: [Double]) -> Double {
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    }

    private static func norm3(_ v: [Double]) -> Double {
        sqrt(dot3(v, v))
    }
}

/// Keeps at most `limit` issues per code and appends a count for the rest, so
/// 5,000 bad frames stay a readable report.
private struct CappedIssues {
    let limit: Int
    private var kept: [CaptureValidationIssue] = []
    private var counts: [String: Int] = [:]
    private var codeOrder: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(code: String, message: String) {
        let count = (counts[code] ?? 0) + 1
        if count == 1 { codeOrder.append(code) }
        counts[code] = count
        if count <= limit {
            kept.append(CaptureValidationIssue(code: code, message: message))
        }
    }

    var list: [CaptureValidationIssue] {
        kept + codeOrder.compactMap { code in
            guard let count = counts[code], count > limit else { return nil }
            return CaptureValidationIssue(
                code: code,
                message: "\(count - limit) more frames failed with \(code)"
            )
        }
    }
}

/// Absolute capture time from the three required EXIF tags:
/// `yyyy:MM:dd HH:mm:ss` local time, a digit-only
/// sub-second fraction and a `±HH:MM` UTC offset.
enum CaptureExifTime {
    static func seconds(
        dateTimeOriginal: String?,
        subSecTimeOriginal: String?,
        offsetTimeOriginal: String?
    ) -> Double? {
        guard let local = localSeconds(dateTimeOriginal),
              let fraction = fraction(subSecTimeOriginal),
              let offset = offsetSeconds(offsetTimeOriginal)
        else {
            return nil
        }
        return local - offset + fraction
    }

    private static func localSeconds(_ text: String?) -> Double? {
        guard let text, text.count == 19 else { return nil }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " }).map { Int($0) }
        guard parts.count == 6, parts.allSatisfy({ $0 != nil }) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts[5]
        )
        return calendar.date(from: components)?.timeIntervalSince1970
    }

    private static func fraction(_ text: String?) -> Double? {
        guard let digits = text?.trimmingCharacters(in: .whitespaces),
              !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit)
        else {
            return nil
        }
        return Double("0.\(digits)")
    }

    private static func offsetSeconds(_ text: String?) -> Double? {
        guard let text, text.count == 6, let sign = text.first, sign == "+" || sign == "-" else {
            return nil
        }
        let hoursMinutes = text.dropFirst().split(separator: ":").map { Int($0) }
        guard hoursMinutes.count == 2, let hours = hoursMinutes[0], let minutes = hoursMinutes[1] else {
            return nil
        }
        return Double((sign == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60))
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
