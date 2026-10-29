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
