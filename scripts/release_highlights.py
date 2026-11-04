#!/usr/bin/env python3
import argparse
import datetime
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


LANGUAGES = (("en", "English"), ("uk", "Українською"))


def validate_entry(entry, language):
    if not isinstance(entry, dict):
        raise ValueError(f"{language} must be an object with headline and highlights")
    headline = entry.get("headline")
    highlights = entry.get("highlights")
    if not isinstance(headline, str) or not headline.strip():
        raise ValueError(f"{language}.headline must be a non-empty string")
    if not isinstance(highlights, list) or not 1 <= len(highlights) <= 3:
        raise ValueError(f"{language}.highlights must contain one to three items")
    if any(not isinstance(item, str) or not item.strip() for item in highlights):
        raise ValueError(f"every {language} highlight must be a non-empty string")


def load_payload(path):
    payload = json.loads(Path(path).read_text(encoding="utf-8"))
    if type(payload.get("schemaVersion")) is not int or payload["schemaVersion"] != 2:
        raise ValueError("schemaVersion must be 2")
    for language, _ in LANGUAGES:
        validate_entry(payload.get(language), language)
    return payload


def render_markdown(payload):
    sections = []
    for language, title in LANGUAGES:
        entry = payload[language]
        sections.append(
            f"## {title}\n\n### {entry['headline']}\n\n"
            + "".join(f"- {item}\n" for item in entry["highlights"])
        )
    return "\n".join(sections)


def render(arguments):
    payload = load_payload(arguments.input)
    output = Path(arguments.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_markdown(payload), encoding="utf-8")


def set_text(parent, tag, value):
    element = parent.find(tag)
    if element is None:
        element = ET.SubElement(parent, tag)
    element.text = value


def ensure_release_notes_links(channel):
    release_notes_tag = f"{{{SPARKLE}}}releaseNotesLink"
    for item in channel.findall("item"):
        existing_link = item.find(release_notes_tag)
        if existing_link is not None and (existing_link.text or "").strip():
            continue
        enclosure = item.find("enclosure")
        download_url = enclosure.get("url") if enclosure is not None else None
        match = re.match(
            r"^(https://github\.com/[^/]+/[^/]+)/releases/download/([^/]+)/",
            download_url or "",
        )
        if match is None:
            raise ValueError("every appcast item must have a release notes link")
        set_text(item, release_notes_tag, f"{match.group(1)}/releases/tag/{match.group(2)}")


def upsert_appcast(arguments):
    if not re.fullmatch(r"\d+\.\d+\.\d+", arguments.version):
        raise ValueError("version must use major.minor.patch")
    if not arguments.build_number.isdigit() or not arguments.length.isdigit():
        raise ValueError("build number and length must be positive integers")

    appcast = Path(arguments.appcast)
    tree = ET.parse(appcast)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise ValueError("appcast is missing its channel")

    version_tag = f"{{{SPARKLE}}}shortVersionString"
    item = next(
        (candidate for candidate in channel.findall("item")
         if candidate.findtext(version_tag) == arguments.version),
        None,
    )
    if item is None:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title")
        ET.SubElement(item, "pubDate").text = arguments.pub_date or datetime.datetime.now(
            datetime.timezone.utc
        ).strftime("%a, %d %b %Y %H:%M:%S %z")

    set_text(item, "title", f"Version {arguments.version}")
    set_text(item, f"{{{SPARKLE}}}version", arguments.build_number)
    set_text(item, version_tag, arguments.version)
    set_text(item, f"{{{SPARKLE}}}releaseNotesLink", arguments.release_notes_url)
    set_text(item, f"{{{SPARKLE}}}minimumSystemVersion", "14.0")

    enclosure = item.find("enclosure")
    if enclosure is None:
        enclosure = ET.SubElement(item, "enclosure")
    enclosure.attrib = {
        "url": arguments.download_url,
        f"{{{SPARKLE}}}edSignature": arguments.signature,
        "length": arguments.length,
        "type": "application/octet-stream",
    }

    ensure_release_notes_links(channel)

    ET.indent(tree, space="  ")
    tree.write(appcast, encoding="utf-8", xml_declaration=True)


def build_parser():
    parser = argparse.ArgumentParser(description="Validate and publish Diduny release highlights")
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser("validate")
    validate.add_argument("input")
    validate.set_defaults(handler=lambda arguments: load_payload(arguments.input))

    render_command = commands.add_parser("render")
    render_command.add_argument("input")
    render_command.add_argument("output")
    render_command.set_defaults(handler=render)

    appcast = commands.add_parser("upsert-appcast")
    appcast.add_argument("appcast")
    appcast.add_argument("--version", required=True)
    appcast.add_argument("--build-number", required=True)
    appcast.add_argument("--download-url", required=True)
    appcast.add_argument("--signature", required=True)
    appcast.add_argument("--length", required=True)
    appcast.add_argument("--release-notes-url", required=True)
    appcast.add_argument("--pub-date")
    appcast.set_defaults(handler=upsert_appcast)
    return parser


def main():
    parser = build_parser()
    arguments = parser.parse_args()
    try:
        arguments.handler(arguments)
    except (OSError, ValueError, json.JSONDecodeError, ET.ParseError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
