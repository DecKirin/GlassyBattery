#!/usr/bin/env bash
#
# Writes a Sparkle appcast with one item: the release being published. It's uploaded with the
# DMG to that release, and the app reads it from the newest release
# (SUFeedURL = https://github.com/DecKirin/GlassyBattery/releases/latest/download/appcast.xml),
# so it only ever needs to describe the newest version.
#
#   scripts/appcast.sh <app> <dmg> <dmg-url> <ed-signature> <notes-html-file> <release-url> > appcast.xml
#
# <app> is the built GlassyBattery.app, read for its version, build and minimum macOS.
# <ed-signature> is `sign_update -p <dmg>`'s output, made with the release key.

set -euo pipefail

[[ $# -eq 6 ]] || { sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
APP=$1 DMG=$2 URL=$3 SIGNATURE=$4 NOTES=$5 RELEASE_URL=$6

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
MIN_OS=$(plist LSMinimumSystemVersion)
LENGTH=$(stat -f%z "$DMG")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
[[ -n "$SIGNATURE" ]] || { echo "error: no EdDSA signature" >&2; exit 1; }

# CDATA can't hold "]]>"; split it if the notes ever contain one.
NOTES_HTML=$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>GlassyBattery</title>
        <link>https://github.com/DecKirin/GlassyBattery</link>
        <item>
            <title>GlassyBattery $VERSION</title>
            <pubDate>$DATE</pubDate>
            <link>$RELEASE_URL</link>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <description><![CDATA[$NOTES_HTML]]></description>
            <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
    </channel>
</rss>
XML
