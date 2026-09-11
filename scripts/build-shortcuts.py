#!/usr/bin/env python3
"""Build reviewable Explorer Link Shortcut artifacts from primary system data.

Focus presets use a native Shortcuts export. Legacy graphs use Apple's bundled
Gallery workflows, Cherri's serialization, and pinned first-party ToolKit action
metadata. This script never reads a user Shortcut database or runs a shortcut.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import uuid

IDS = ("focus.on", "focus.off", "silent.on", "silent.off", "notes.create", "notes.browse")
URL_PREFIX = "explorerlink://preview?text={percent_encoded_note_text}"
WEATHER_IDENTIFIER = "is.workflow.actions.weather.currentconditions"
WEATHER_DETAIL_IDENTIFIER = "is.workflow.actions.properties.weather.conditions"
SHAZAM_IDENTIFIER = "is.workflow.actions.shazamMedia"
SHAZAM_DETAIL_IDENTIFIER = "is.workflow.actions.properties.shazam"
URL_ENCODE_IDENTIFIER = "is.workflow.actions.urlencode"
TEXT_IDENTIFIER = "is.workflow.actions.gettext"
OPEN_URL_IDENTIFIER = "is.workflow.actions.openurl"
FILTER_NOTES_IDENTIFIER = "is.workflow.actions.filter.notes"
CHOOSE_FROM_LIST_IDENTIFIER = "is.workflow.actions.choosefromlist"
DETECT_TEXT_IDENTIFIER = "is.workflow.actions.detect.text"
ASK_IDENTIFIER = "is.workflow.actions.ask"
SILENT_IDENTIFIER = "com.apple.ShortcutsActions.SetSilentModeAction"

INPUT_CLASSES = [
    "WFAppContentItem", "WFAppStoreAppContentItem", "WFArticleContentItem",
    "WFContactContentItem", "WFDateContentItem", "WFEmailAddressContentItem",
    "WFFolderContentItem", "WFGenericFileContentItem", "WFImageContentItem",
    "WFiTunesProductContentItem", "WFLocationContentItem", "WFDCMapsLinkContentItem",
    "WFAVAssetContentItem", "WFPDFContentItem", "WFPhoneNumberContentItem",
    "WFRichTextContentItem", "WFSafariWebPageContentItem", "WFStringContentItem",
    "WFURLContentItem",
]


def load(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not {"id", "name", "summary", "foreground_review", "actions"}.issubset(value) or set(value) - {"id", "name", "summary", "foreground_review", "actions", "availability"}:
        raise ValueError(f"unexpected fields: {path.name}")
    if value["id"] not in IDS or not isinstance(value["name"], str) or not isinstance(value["summary"], str):
        raise ValueError(f"invalid identity: {path.name}")
    if value["foreground_review"] is not True or not isinstance(value["actions"], list) or not value["actions"]:
        raise ValueError(f"missing review/action flow: {path.name}")
    for action in value["actions"]:
        if set(action) != {"kind", "label", "parameters"} or action["kind"] not in ("system_action", "open_url"):
            raise ValueError(f"invalid action: {path.name}")
        if not isinstance(action["label"], str) or not isinstance(action["parameters"], dict):
            raise ValueError(f"invalid action fields: {path.name}")
    if value["id"] in ("notes.browse", "notes.create"):
        if value["actions"][-1]["parameters"].get("url") != URL_PREFIX:
            raise ValueError("notes must hand off only to the reviewed preview URL")
        if value.get("availability") not in (None, "public_app_url_contract"):
            raise ValueError("notes must use the public preview URL contract")
        if value["id"] == "notes.create" and value["actions"][-1]["parameters"].get("save") != "user_taps_save_as_note":
            raise ValueError("note creation must require explicit local save")
    elif any(action["kind"] == "open_url" for action in value["actions"]):
        raise ValueError(f"unexpected URL handoff: {path.name}")
    return value


def build(templates: Path, output: Path) -> list[dict]:
    loaded = [(path, load(path)) for path in templates.glob("*.json")]
    by_id = {value["id"]: path for path, value in loaded}
    if len(loaded) != len(IDS) or set(by_id) != set(IDS):
        raise ValueError("templates must contain each fixed phone action once, in catalog order")
    files = [by_id[identifier] for identifier in IDS]
    values = [load(path) for path in files]
    output.mkdir(parents=True, exist_ok=True)
    for path in files:
        shutil.copyfile(path, output / path.name)
    (output / "catalog.json").write_text(json.dumps({"version": 1, "templates": values,
        "shortcutFiles": "Signed .shortcut presets ship separately. Signing validates the artifact format; real iPhone execution remains unverified."}, indent=2) + "\n", encoding="utf-8")
    return values


def sign(source: Path, destination: Path) -> None:
    if source.suffix != ".shortcut" or not source.is_file() or source.is_symlink():
        raise ValueError("--sign-input must be one regular synthetic legacy .shortcut file")
    subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", str(source), "--output", str(destination)], check=True)


def output_token(output_name: str, output_uuid: str) -> dict:
    """Old-format token shape copied from Apple’s bundled MorningReport.wflow."""
    return {"Value": {"attachmentsByRange": {"{0, 1}": {
        "OutputName": output_name, "OutputUUID": output_uuid, "Type": "ActionOutput"}},
        "string": "\ufffc"}, "WFSerializationType": "WFTextTokenString"}


def output_attachment(output_name: str, output_uuid: str) -> dict:
    return {"Value": {"OutputName": output_name, "OutputUUID": output_uuid,
                      "Type": "ActionOutput"},
            "WFSerializationType": "WFTextTokenAttachment"}


def base_workflow(actions: list[dict]) -> dict:
    """Metadata copied from the native exported one-action Focus shortcut."""
    return {
        "WFQuickActionSurfaces": [],
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "5037.0.17",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 61440,
                           "WFWorkflowIconStartColor": -1263359489},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": INPUT_CLASSES,
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": ["WFWorkflowTypeShowInSearch"],
    }


def action(identifier: str, parameters: dict | None = None) -> tuple[dict, str]:
    action_uuid = str(uuid.uuid4()).upper()
    values = dict(parameters or {})
    values["UUID"] = action_uuid
    return {"WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": values}, action_uuid


def preview_handoff(source_name: str, source_uuid: str) -> list[dict]:
    """Encode an action output and open Explorer Link's foreground preview."""
    encode, encode_uuid = action(URL_ENCODE_IDENTIFIER, {
        "WFInput": output_token(source_name, source_uuid),
        "WFEncodeMode": "Encode",
    })
    text, text_uuid = text_from_outputs([
        "explorerlink://preview?text=", ("URL Encoded Text", encode_uuid)])
    open_url, _ = action(OPEN_URL_IDENTIFIER, {
        "Show-WFInput": True,
        "WFInput": output_attachment("Text", text_uuid),
    })
    return [encode, text, open_url]


def text_from_outputs(parts: list[str | tuple[str, str]]) -> tuple[dict, str]:
    """Compose a WFTextTokenString with exact action-output attachments."""
    text = ""
    attachments = {}
    for part in parts:
        if isinstance(part, tuple):
            # NSRange indexes UTF-16 code units, not Python Unicode scalars.
            attachments[f"{{{len(text.encode('utf-16-le')) // 2}, 1}}"] = {"OutputName": part[0],
                                                  "OutputUUID": part[1],
                                                  "Type": "ActionOutput"}
            text += "\ufffc"
        else:
            text += part
    text_action, text_uuid = action(TEXT_IDENTIFIER, {
        "WFTextActionText": {"Value": {"string": text,
                                           "attachmentsByRange": attachments},
                             "WFSerializationType": "WFTextTokenString"},
    })
    return text_action, text_uuid


def legacy_preset(name: str, destination: Path) -> None:
    """Write a synthetic, unsigned legacy graph; signing is separate."""
    if name in ("silent-on", "silent-off"):
        # Exact action, parameter keys and enum value from Apple's ToolKit
        # metadata extracted at viticci/shortcuts-playground-plugin commit
        # 2de03bffe4ce8802e06d184931d9e4ec366a2ef2:
        # codex/skills/shortcuts-playground/data/toolkit-v78-first-party-
        # {parameter-keys,enum-cases}.json. Generic AppIntentDescriptor shape:
        # electrikmilk/cherri action.go appIntentDescriptor(). Bundle name/ID
        # also match the iOS 18.5 ShortcutsActions.app Info.plist.
        silent, _ = action(SILENT_IDENTIFIER, {
            "operation": "turn", "state": name == "silent-on",
            "AppIntentDescriptor": {
                "AppIntentIdentifier": "SetSilentModeAction",
                "BundleIdentifier": "com.apple.ShortcutsActions",
                "Name": "ShortcutsActions", "TeamIdentifier": "0000000000",
            },
        })
        actions = [silent]
    elif name == "notes-create":
        # Apple's Gallery.bundle/Contents/Resources/Haiku.wflow supplies
        # is.workflow.actions.ask + WFAskActionPrompt. Cherri actions_std.go
        # "prompt" supplies WFInputType=Text. No Apple Notes mutation occurs:
        # the URL opens Explorer Link's draft, with explicit local save/send.
        ask, ask_uuid = action(ASK_IDENTIFIER, {
            "WFAskActionPrompt": "Quick note", "WFInputType": "Text",
        })
        actions = [ask, *preview_handoff("Provided Input", ask_uuid)]
    elif name == "weather":
        current, current_uuid = action(WEATHER_IDENTIFIER)
        detail, detail_uuid = action(WEATHER_DETAIL_IDENTIFIER, {
            "WFInput": output_attachment("Weather Conditions", current_uuid),
            "WFContentItemPropertyName": "Condition",
        })
        temperature, temperature_uuid = action(WEATHER_DETAIL_IDENTIFIER, {
            "WFInput": output_attachment("Weather Conditions", current_uuid),
            "WFContentItemPropertyName": "Temperature",
        })
        text, text_uuid = text_from_outputs(["Condition: ", ("Condition", detail_uuid),
                                              "\nTemperature: ", ("Temperature", temperature_uuid)])
        actions = [current, detail, temperature, text, *preview_handoff("Text", text_uuid)]
    elif name == "shazam":
        recognize, recognize_uuid = action(SHAZAM_IDENTIFIER, {
            "WFShazamMediaActionShowWhenRun": True,
            "WFShazamMediaActionErrorIfNotRecognized": True,
        })
        detail, detail_uuid = action(SHAZAM_DETAIL_IDENTIFIER, {
            "WFInput": output_attachment("Shazam Media", recognize_uuid),
            "WFContentItemPropertyName": "Title",
        })
        artist, artist_uuid = action(SHAZAM_DETAIL_IDENTIFIER, {
            "WFInput": output_attachment("Shazam Media", recognize_uuid),
            "WFContentItemPropertyName": "Artist",
        })
        text, text_uuid = text_from_outputs(["Title: ", ("Title", detail_uuid),
                                              "\nArtist: ", ("Artist", artist_uuid)])
        actions = [recognize, detail, artist, text, *preview_handoff("Text", text_uuid)]
    elif name == "notes-browse":
        notes, notes_uuid = action(FILTER_NOTES_IDENTIFIER, {
            "AppIntentDescriptor": {
                "ActionRequiresAppInstallation": True,
                "AppIntentIdentifier": "NoteEntity",
                "BundleIdentifier": "com.apple.mobilenotes",
                "Name": "Notes",
                "TeamIdentifier": "0000000000",
            },
        })
        choose, choose_uuid = action(CHOOSE_FROM_LIST_IDENTIFIER, {
            "WFInput": output_attachment("Note", notes_uuid),
        })
        text, text_uuid = action(DETECT_TEXT_IDENTIFIER, {
            "WFInput": output_attachment("Chosen Item", choose_uuid),
        })
        actions = [notes, choose, text, *preview_handoff("Text", text_uuid)]
    else:
        raise ValueError(f"unsupported preset: {name}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        plistlib.dump(base_workflow(actions), output, fmt=plistlib.FMT_BINARY, sort_keys=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--templates", type=Path, default=Path("apple/iOS/Resources/ShortcutTemplates"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sign-input", type=Path)
    parser.add_argument("--sign-output", type=Path)
    parser.add_argument("--preset", choices=("weather", "shazam", "notes-browse", "notes-create", "silent-on", "silent-off"),
                        help="synthetic graph to write")
    parser.add_argument("--legacy-output", type=Path,
                        help="destination for unsigned old-format .shortcut source")
    args = parser.parse_args()
    build(args.templates, args.output)
    if (args.sign_input is None) != (args.sign_output is None):
        parser.error("--sign-input and --sign-output must be supplied together")
    if args.sign_input:
        sign(args.sign_input, args.sign_output)
    if (args.preset is None) != (args.legacy_output is None):
        parser.error("--preset and --legacy-output must be supplied together")
    if args.legacy_output:
        if args.legacy_output.suffix != ".shortcut":
            parser.error("--legacy-output must end in .shortcut")
        legacy_preset(args.preset, args.legacy_output)
