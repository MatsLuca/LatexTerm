import Foundation

// Kachel `diff` (26.09.2026): git diff → Dateien, Abschnitte, Zeilennummern, Summen.
@main
struct DiffModelTests {
    static func main() {
        let sample = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,4 +10,5 @@ struct App {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        \\ No newline at end of file
        diff --git a/neu.txt b/neu.txt
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/neu.txt
        @@ -0,0 +1,2 @@
        +eins
        +zwei
        diff --git a/weg.md b/weg.md
        deleted file mode 100644
        index 4444444..0000000
        --- a/weg.md
        +++ /dev/null
        @@ -1 +0,0 @@
        -alt
        diff --git a/alt name.txt b/neu name.txt
        similarity index 90%
        rename from alt name.txt
        rename to neu name.txt
        diff --git a/logo.png b/logo.png
        index 5555555..6666666 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git "a/sch\\303\\266n \\"x\\".txt" "b/sch\\303\\266n \\"x\\".txt"
        index 7777777..8888888 100644
        --- "a/sch\\303\\266n \\"x\\".txt"
        +++ "b/sch\\303\\266n \\"x\\".txt"
        @@ -1 +1 @@
        -a
        +b

        """
        let files = DiffModel.parse(sample)
        assert(files.count == 6, "\(files.count) Dateien")
        let app = files[0]
        assert(app.path == "Sources/App.swift" && app.status == .modified && app.added == 2 && app.removed == 1)
        let lines = app.hunks[0].lines
        assert(lines.count == 6, "\(lines.count)")
        assert(lines[0] == .init(kind: .context, old: 10, new: 10, text: "let a = 1"))
        assert(lines[1] == .init(kind: .del, old: 11, new: nil, text: "let b = 2"))
        assert(lines[2] == .init(kind: .add, old: nil, new: 11, text: "let b = 3"))
        assert(lines[3] == .init(kind: .add, old: nil, new: 12, text: "let c = 4"))
        assert(lines[4] == .init(kind: .context, old: 12, new: 13, text: "let d = 5"))
        assert(lines[5].kind == .note && lines[5].text == "No newline at end of file")
        assert(files[1].path == "neu.txt" && files[1].status == .added && files[1].added == 2 && files[1].hunks[0].lines[1].new == 2)
        assert(files[2].path == "weg.md" && files[2].status == .deleted && files[2].removed == 1)
        assert(files[3].path == "neu name.txt" && files[3].oldPath == "alt name.txt" && files[3].status == .renamed && files[3].metaOnly)
        assert(files[4].path == "logo.png" && files[4].binary && !files[4].metaOnly)
        assert(files[5].path == "schön \"x\".txt", files[5].path)
        let totals = DiffModel.totals(files)
        assert(totals.added == 5 && totals.removed == 3, "\(totals)")
        assert(DiffModel.label(added: 42, removed: 7) == "+42 −7")
        assert(DiffModel.hunkStart("@@ -3 +4,2 @@") == (3, 4))

        // Grenze: gezählt wird alles, gezeigt bis zum Limit.
        let long = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,0 +1,5 @@\n+1\n+2\n+3\n+4\n+5\n"
        let cut = DiffModel.parse(long, lineLimit: 3)[0]
        assert(cut.added == 5 && cut.truncated && cut.hunks[0].lines.count == 3)

        // Unversionierte Datei: Text ganz als neu, Binäres erkannt.
        let fresh = DiffModel.untracked(path: "a.txt", data: Data("x\ny\n".utf8))
        assert(fresh.status == .untracked && fresh.added == 2 && fresh.hunks[0].lines[1] == .init(kind: .add, old: nil, new: 2, text: "y"))
        assert(DiffModel.untracked(path: "b.bin", data: Data([0, 1, 2])).binary)
        assert(DiffModel.untracked(path: "leer", data: Data()).hunks.isEmpty)

        // Nutzlast für die Seite: Grundtypen, JSON-fähig.
        assert(JSONSerialization.isValidJSONObject(DiffModel.payload(files)))
        print("diff-model: ok")
    }
}
