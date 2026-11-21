from pathlib import Path
import shutil
import unittest
import uuid

from identity import Workspace


class Content(Workspace):
    def test_portability_and_relationships(self):
        space = self.call("GET", "spaces", session=self.admin)[1]["spaces"][0]["id"]
        base = f"spaces/{space}/"
        for folder in ["Research", "Cycles", "Engineering"]:
            self.call("POST", base + "directory", {"path": folder}, self.admin, 204)
        root = Path(self.home.name) / "content/spaces" / space
        plain = root / "Research/notes.md"
        plain.write_text("# Field notes\n")
        def tree():
            return self.call("GET", base + "tree", session=self.admin)[1]["documents"]
        self.assertIsNone(tree()[0].get("id"))
        self.assertEqual(plain.read_text(), "# Field notes\n")
        def write(path, text, **fields):
            self.call("POST", base + "write", dict(path=path, text=text, **fields), self.admin, 204)
        release, sprint, task, url = [str(uuid.uuid4()) for _ in range(4)]
        for kind, entity, path, fields in [
            ("release", release, "Research/version.md", ""),
            ("sprint", sprint, "Cycles/nov.md", f"release: {release}\n"),
            ("task", task, "Engineering/work.md", f"status: todo\nsprint: {sprint}\nrelease: {release}\n"),
            ("url", url, "Research/source.md", "url: https://example.org/\n")]:
            write(path, f"---\nid: {entity}\ntype: {kind}\ntitle: Example\n{fields}---\nNotes")
        task_doc = next(d for d in tree() if d.get("id") == task)
        self.assertEqual((task_doc["sprint"], task_doc["release"]), (sprint, release))
        old = next(d for d in tree() if d["path"] == "Research/notes.md")
        write(old["path"], "updated", revision=old["revision"])
        self.call("POST", base + "write", dict(path=old["path"], text="stale", revision=old["revision"]), self.admin, 409)
        copy = Path(self.home.name) / "copied"
        shutil.copytree(root, copy)
        self.assertIn(f"sprint: {sprint}", (copy / task_doc["path"]).read_text())
        self.assertEqual((copy / old["path"]).read_text(), "updated")


if __name__ == "__main__":
    unittest.main()
