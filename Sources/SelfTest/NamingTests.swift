import Foundation
import Core

func namingTests() {
    check(Naming.label(forFolder: "2026-10 Bali") == "Bali", "label strips YYYY-MM")
    check(Naming.label(forFolder: "2026-10-03 - Bali trip") == "Bali trip", "label strips YYYY-MM-DD and dash")
    check(Naming.label(forFolder: "2026-10") == "2026-10", "date-only folder keeps whole name")
    check(Naming.label(forFolder: "Bali") == "Bali", "no date prefix unchanged")

    check(Naming.fileName(label: "Bali", number: 1, ext: "HEIC") == "Bali 01.HEIC", "2-digit padding")
    check(Naming.fileName(label: "Bali", number: 100, ext: "HEIC") == "Bali 100.HEIC", "grows past 99")
    check(Naming.originalName(besideEditedCopy: "/Vol/Memories/IMG_9597.heic", ext: "HEIC") == "IMG_9597 original.HEIC", "original copy name uses phone extension")
    check(Naming.originalName(besideEditedCopy: "/Vol/Memories/IMG_9597", ext: "") == "IMG_9597 original", "original copy name has no trailing dot without extension")

    let names = ["Bali 01.HEIC", "bali 03.mov", "Bali trip 02.JPG", "Other 05.JPG", ".photo-backup-receipt.json"]
    check(Naming.existingNumbers(label: "Bali", in: names) == [1, 3], "existing numbers only for this label, case-insensitive")

    // RF 5
    check(Naming.nextNumbers(count: 2, label: "Bali", existing: ["Bali 01.HEIC", "BALI 02.mov"]) == [3, 4], "numbering continues after highest")
    check(Naming.nextNumbers(count: 1, label: "Bali", existing: []) == [1], "empty folder starts at 1")

    // RF 3
    for bad in ["", "   ", "a/b", "a:b", ".hidden"] {
        check(Naming.validateFolderName(bad) != nil, "rejects folder name '\(bad)'")
    }
    check(Naming.validateFolderName("2026-10 Bali") == nil, "accepts normal folder name")
}

func folderPrefixTests() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "T10:00:00Z")! }
    check(Naming.folderPrefix(dates: [d("2026-10-05"), d("2026-10-05")], calendar: cal) == "2026-10-05 ", "one day: year-month-day")
    check(Naming.folderPrefix(dates: [d("2026-10-05"), d("2026-10-20")], calendar: cal) == "2026-10 ", "one month: year-month")
    check(Naming.folderPrefix(dates: [d("2026-03-05"), d("2026-10-05")], calendar: cal) == "2026 ", "one year, same day number in two months: year")
    check(Naming.folderPrefix(dates: [d("2025-10-05"), d("2026-10-05")], calendar: cal) == "", "several years: no suggestion")
    check(Naming.folderPrefix(dates: [], calendar: cal) == "", "no dates: no suggestion")
}

func pathInsideTests() {
    let root = URL(fileURLWithPath: "/Volumes/D/Memories")
    check(Naming.pathInside(root, folder: URL(fileURLWithPath: "/Volumes/D/Memories/2026-10 Bali")) == "2026-10 Bali", "a folder inside the backup folder")
    check(Naming.pathInside(root, folder: URL(fileURLWithPath: "/Volumes/D/Memories/2024/Bali")) == "2024/Bali", "a folder inside a folder")
    check(Naming.pathInside(root, folder: URL(fileURLWithPath: "/Volumes/D/Other")) == nil, "a folder outside is refused")
    check(Naming.pathInside(root, folder: root) == nil, "the backup folder itself is refused")
    check(Naming.pathInside(root, folder: URL(fileURLWithPath: "/Volumes/D/Memories2/x")) == nil, "a look-alike name is outside")
    check(Naming.pathInside(root, folder: URL(fileURLWithPath: "/Volumes/D/Memories/a/../../Other")) == nil, "climbing out with .. is outside")
}
