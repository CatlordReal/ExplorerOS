#!/usr/bin/env python3
"""Pure validation for reviewable Shortcuts templates; does not access Shortcuts data."""
from __future__ import annotations
import json
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
artifacts = json.loads((ROOT / "fixtures/shortcut-artifacts.json").read_text())["artifacts"]
signed_directory = ROOT / "apple/iOS/Resources/ShortcutTemplates"
assert len(artifacts) == 8
assert {record["file"] for record in artifacts} == {path.name for path in signed_directory.glob("*.shortcut")}
for record in artifacts:
    blob = (signed_directory / record["file"]).read_bytes()
    assert blob.startswith(b"AEA1")
    assert hashlib.sha256(blob).hexdigest() == record["binary_sha256"], record["file"]

spec = importlib.util.spec_from_file_location("shortcut_builder", ROOT / "scripts/build-shortcuts.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

def check_handoff(actions):
    encode, text, open_url = [item["WFWorkflowActionParameters"] for item in actions[-3:]]
    value = text["WFTextActionText"]["Value"]
    assert value["string"] == "explorerlink://preview?text=\ufffc"
    assert value["attachmentsByRange"] == {"{28, 1}": {
        "OutputName": "URL Encoded Text", "OutputUUID": encode["UUID"], "Type": "ActionOutput"}}
    assert open_url["WFInput"]["Value"]["OutputUUID"] == text["UUID"]
    assert open_url["WFInput"]["Value"]["OutputName"] == "Text"

with tempfile.TemporaryDirectory() as temporary:
    output = Path(temporary) / "generated"
    subprocess.run([sys.executable, str(ROOT / "scripts/build-shortcuts.py"), "--output", str(output)], cwd=ROOT, check=True)
    catalog = json.loads((output / "catalog.json").read_text())
    assert [item["id"] for item in catalog["templates"]] == ["focus.on", "focus.off", "silent.on", "silent.off", "notes.create", "notes.browse"]
    browse = catalog["templates"][-1]
    assert browse["availability"] == "public_app_url_contract"
    assert browse["actions"][-1]["parameters"]["url"] == "explorerlink://preview?text={percent_encoded_note_text}"
    assert browse["actions"][-1]["parameters"]["send"] == "user_taps_send"
    create = catalog["templates"][-2]
    assert create["actions"][-1]["parameters"]["save"] == "user_taps_save_as_note"
    assert create["actions"][-1]["parameters"]["url"] == builder.URL_PREFIX
    assert not list(output.glob("*.shortcut"))
    weather = Path(temporary) / "Explorer Weather.shortcut"
    subprocess.run([sys.executable, str(ROOT / "scripts/build-shortcuts.py"), "--output", str(output),
                    "--preset", "weather", "--legacy-output", str(weather)], cwd=ROOT, check=True)
    import plistlib
    legacy = plistlib.load(weather.open("rb"))
    actions = legacy["WFWorkflowActions"]
    assert [action["WFWorkflowActionIdentifier"] for action in actions] == [
        "is.workflow.actions.weather.currentconditions",
        "is.workflow.actions.properties.weather.conditions",
        "is.workflow.actions.properties.weather.conditions",
        "is.workflow.actions.gettext",
        "is.workflow.actions.urlencode", "is.workflow.actions.gettext",
        "is.workflow.actions.openurl"]
    assert actions[1]["WFWorkflowActionParameters"]["WFContentItemPropertyName"] == "Condition"
    assert actions[2]["WFWorkflowActionParameters"]["WFContentItemPropertyName"] == "Temperature"
    assert actions[3]["WFWorkflowActionParameters"]["WFTextActionText"]["Value"]["string"] == "Condition: \ufffc\nTemperature: \ufffc"
    assert actions[4]["WFWorkflowActionParameters"]["WFEncodeMode"] == "Encode"
    assert actions[5]["WFWorkflowActionParameters"]["WFTextActionText"]["Value"]["string"] == "explorerlink://preview?text=\ufffc"
    assert actions[6]["WFWorkflowActionParameters"]["Show-WFInput"] is True
    shazam = Path(temporary) / "Explorer Recognize Music.shortcut"
    subprocess.run([sys.executable, str(ROOT / "scripts/build-shortcuts.py"), "--output", str(output),
                    "--preset", "shazam", "--legacy-output", str(shazam)], cwd=ROOT, check=True)
    shazam_actions = plistlib.load(shazam.open("rb"))["WFWorkflowActions"]
    assert [action["WFWorkflowActionIdentifier"] for action in shazam_actions] == [
        "is.workflow.actions.shazamMedia", "is.workflow.actions.properties.shazam",
        "is.workflow.actions.properties.shazam", "is.workflow.actions.gettext",
        "is.workflow.actions.urlencode", "is.workflow.actions.gettext",
        "is.workflow.actions.openurl"]
    assert shazam_actions[0]["WFWorkflowActionParameters"]["WFShazamMediaActionShowWhenRun"] is True
    assert shazam_actions[1]["WFWorkflowActionParameters"]["WFContentItemPropertyName"] == "Title"
    assert shazam_actions[2]["WFWorkflowActionParameters"]["WFContentItemPropertyName"] == "Artist"
    assert shazam_actions[3]["WFWorkflowActionParameters"]["WFTextActionText"]["Value"]["string"] == "Title: \ufffc\nArtist: \ufffc"
    notes = Path(temporary) / "Explorer Browse Notes.shortcut"
    subprocess.run([sys.executable, str(ROOT / "scripts/build-shortcuts.py"), "--output", str(output),
                    "--preset", "notes-browse", "--legacy-output", str(notes)], cwd=ROOT, check=True)
    notes_actions = plistlib.load(notes.open("rb"))["WFWorkflowActions"]
    assert [action["WFWorkflowActionIdentifier"] for action in notes_actions] == [
        "is.workflow.actions.filter.notes", "is.workflow.actions.choosefromlist",
        "is.workflow.actions.detect.text", "is.workflow.actions.urlencode",
        "is.workflow.actions.gettext", "is.workflow.actions.openurl"]
    descriptor = notes_actions[0]["WFWorkflowActionParameters"]["AppIntentDescriptor"]
    assert descriptor == {"ActionRequiresAppInstallation": True, "AppIntentIdentifier": "NoteEntity",
                          "BundleIdentifier": "com.apple.mobilenotes", "Name": "Notes",
                          "TeamIdentifier": "0000000000"}
    for graph in (actions, shazam_actions, notes_actions):
        check_handoff(graph)
    for preset in ("silent-on", "silent-off", "notes-create"):
        path = Path(temporary) / (preset + ".shortcut")
        builder.legacy_preset(preset, path)
        graph = plistlib.loads(path.read_bytes())["WFWorkflowActions"]
        if preset == "notes-create":
            assert [item["WFWorkflowActionIdentifier"] for item in graph] == [
                builder.ASK_IDENTIFIER, builder.URL_ENCODE_IDENTIFIER,
                builder.TEXT_IDENTIFIER, builder.OPEN_URL_IDENTIFIER]
            assert graph[0]["WFWorkflowActionParameters"]["WFInputType"] == "Text"
            assert graph[1]["WFWorkflowActionParameters"]["WFInput"]["Value"]["attachmentsByRange"]["{0, 1}"]["OutputUUID"] == graph[0]["WFWorkflowActionParameters"]["UUID"]
            check_handoff(graph)
        else:
            assert len(graph) == 1
            assert graph[0]["WFWorkflowActionIdentifier"] == builder.SILENT_IDENTIFIER
            parameters = graph[0]["WFWorkflowActionParameters"]
            assert parameters["operation"] == "turn"
            assert parameters["state"] is (preset == "silent-on")
    astral, _ = builder.text_from_outputs(["😀", ("Result", "test-output")])
    assert set(astral["WFWorkflowActionParameters"]["WFTextActionText"]["Value"]["attachmentsByRange"]) == {"{2, 1}"}
print("ShortcutTemplatesTest: PASS")
