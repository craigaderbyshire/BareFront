#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import re
import sys

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


# ------------------------------------------------------------
# BareFront multidisc organiser
#
# FIRST CANDIDATE:
#   * READ ONLY
#   * NO --apply MODE
#   * NO FILE CREATION
#   * NO ROM MOVES
#
# It analyses the currently active ROM tree and reports what a
# future transactional apply mode would do.
# ------------------------------------------------------------


MEDIA_EXTENSIONS = {
    ".adf",
    ".chd",
    ".cue",
    ".d64",
    ".d71",
    ".d81",
    ".g64",
    ".gcm",
    ".gdi",
    ".iso",
    ".ipf",
    ".rvz",
}


DISC_PATTERN = re.compile(
    r"""
    (?P<whole>
        (?:^|[\s._-]+)
        [(\[\{]?
        \s*
        (?P<label>disc|disk|cd)
        [\s._-]*
        0*
        (?P<number>[1-9][0-9]*)
        \s*
        [)\]\}]?
    )
    """,
    re.IGNORECASE | re.VERBOSE,
)


CUE_FILE_PATTERN = re.compile(
    r"""
    ^\s*
    FILE
    \s+
    (?:
        "([^"]+)"
        |
        (\S+)
    )
    \s+
    """,
    re.IGNORECASE | re.VERBOSE,
)


WINDOWS_ABSOLUTE_PATTERN = re.compile(
    r"^[A-Za-z]:"
)


@dataclass
class DiscUnit:
    path: Path
    disc_number: int
    base_name: str
    dependencies: tuple[Path, ...]


def inside(root: Path, target: Path) -> bool:
    try:
        target.relative_to(root)
        return True
    except ValueError:
        return False


def relative_text(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return str(path)


def normalise_name(text: str) -> str:
    text = text.casefold()
    text = re.sub(r"[\s._-]+", " ", text)
    return text.strip()


def remove_parenthetical_tags(text: str) -> str:
    result = re.sub(
        r"\s*[\(\[].*?[\)\]]",
        "",
        text
    )

    result = re.sub(
        r"\s+",
        " ",
        result
    )

    return result.strip(" ._-")


def disc_identity(path: Path):
    stem = path.stem

    match = DISC_PATTERN.search(stem)

    if not match:
        return None

    number = int(match.group("number"))

    base = (
        stem[:match.start("whole")] +
        stem[match.end("whole"):]
    )

    base = re.sub(
        r"[\s._-]+$",
        "",
        base
    )

    base = re.sub(
        r"^[\s._-]+",
        "",
        base
    )

    base = re.sub(
        r"\s+",
        " ",
        base
    )

    if not base:
        return None

    return number, base


def parse_cue_dependencies(cue: Path) -> tuple[Path, ...]:
    dependencies: list[Path] = []

    try:
        with cue.open(
            "r",
            encoding="utf-8-sig",
            errors="strict"
        ) as handle:
            for line_number, line in enumerate(handle, 1):
                match = CUE_FILE_PATTERN.search(line)

                if not match:
                    continue

                reference = match.group(1) or match.group(2)

                if "\\" in reference:
                    raise RuntimeError(
                        f"{cue.name}: line {line_number}: "
                        "backslash path separator"
                    )

                if WINDOWS_ABSOLUTE_PATTERN.match(reference):
                    raise RuntimeError(
                        f"{cue.name}: line {line_number}: "
                        "Windows absolute path"
                    )

                relative = Path(reference)

                if relative.is_absolute():
                    raise RuntimeError(
                        f"{cue.name}: line {line_number}: "
                        "absolute path"
                    )

                if ".." in relative.parts:
                    raise RuntimeError(
                        f"{cue.name}: line {line_number}: "
                        "parent-directory traversal"
                    )

                dependency = (
                    cue.parent /
                    relative
                ).resolve(strict=True)

                root = cue.parent.resolve(strict=True)

                if not inside(root, dependency):
                    raise RuntimeError(
                        f"{cue.name}: line {line_number}: "
                        "dependency escapes disc directory"
                    )

                if not dependency.is_file():
                    raise RuntimeError(
                        f"{cue.name}: line {line_number}: "
                        "dependency is not a regular file"
                    )

                if dependency not in dependencies:
                    dependencies.append(dependency)

    except UnicodeDecodeError as error:
        raise RuntimeError(
            f"{cue.name}: cannot decode CUE as UTF-8: {error}"
        ) from error

    if not dependencies:
        raise RuntimeError(
            f"{cue.name}: no FILE dependencies found"
        )

    return tuple(dependencies)


def validate_m3u(
    playlist: Path
) -> tuple[list[Path], str | None]:

    verified: list[Path] = []

    try:
        playlist_parent = (
            playlist.absolute()
            .parent
            .resolve(strict=True)
        )

        actual_playlist = playlist.resolve(strict=True)

        if not inside(
            playlist_parent,
            actual_playlist
        ):
            raise RuntimeError(
                "Playlist resolves outside its game directory"
            )

        if not actual_playlist.is_file():
            raise RuntimeError(
                "Playlist is not a regular file"
            )

        seen: set[Path] = set()

        with playlist.open(
            "r",
            encoding="utf-8-sig",
            errors="strict"
        ) as handle:

            for line_number, raw_line in enumerate(handle, 1):

                line = raw_line.strip()

                if not line or line.startswith("#"):
                    continue

                def reject(reason: str):
                    raise RuntimeError(
                        f"Line {line_number}: {reason}"
                    )

                if "\x00" in line:
                    reject(
                        "NUL character in media path"
                    )

                if "\\" in line:
                    reject(
                        "Backslash path separator"
                    )

                if WINDOWS_ABSOLUTE_PATTERN.match(line):
                    reject(
                        "Windows absolute path"
                    )

                relative = Path(line)

                if relative.is_absolute():
                    reject(
                        "Absolute path"
                    )

                if ".." in relative.parts:
                    reject(
                        "Parent-directory traversal"
                    )

                try:
                    resolved = (
                        playlist_parent /
                        relative
                    ).resolve(strict=True)
                except FileNotFoundError:
                    reject(
                        "Referenced media is missing "
                        "or not a regular file"
                    )

                if not inside(
                    playlist_parent,
                    resolved
                ):
                    reject(
                        "Media resolves outside game directory"
                    )

                if resolved == actual_playlist:
                    reject(
                        "Playlist references itself"
                    )

                if not resolved.is_file():
                    reject(
                        "Referenced media is missing "
                        "or not a regular file"
                    )

                if resolved in seen:
                    reject(
                        "Duplicate media path"
                    )

                seen.add(resolved)
                verified.append(resolved)

    except (
        OSError,
        RuntimeError,
        UnicodeDecodeError
    ) as error:
        return verified, str(error)

    if not verified:
        return (
            verified,
            "Playlist contains no media"
        )

    return verified, None


def parse_vfl_claims(vfl: Path) -> set[Path]:
    claims: set[Path] = set()

    try:
        with vfl.open(
            "r",
            encoding="utf-8-sig",
            errors="replace"
        ) as handle:

            for raw_line in handle:
                line = raw_line.strip()

                if not line or line.startswith(";"):
                    continue

                media = Path(line)

                if not media.is_absolute():
                    media = vfl.parent / media

                try:
                    resolved = media.resolve(strict=True)
                except OSError:
                    continue

                if resolved.is_file():
                    claims.add(resolved)

    except OSError:
        pass

    return claims


def collect_playlists(root: Path):
    playlists = sorted(
        path
        for path in root.rglob("*")
        if (
            path.is_file() and
            path.suffix.casefold() == ".m3u"
        )
    )

    verified_by_playlist: dict[Path, list[Path]] = {}
    errors: dict[Path, list[str]] = defaultdict(list)
    claims: dict[Path, set[Path]] = defaultdict(set)

    for playlist in playlists:
        verified, error = validate_m3u(playlist)

        verified_by_playlist[playlist] = verified

        if error:
            errors[playlist].append(error)

        for media in verified:
            claims[media].add(playlist)

    for media, owners in claims.items():
        if len(owners) <= 1:
            continue

        message = (
            "Disc image claimed by multiple playlists: " +
            relative_text(root, media)
        )

        for playlist in owners:
            errors[playlist].append(message)

    return (
        playlists,
        verified_by_playlist,
        errors,
        claims,
    )


def collect_vfl_claims(root: Path) -> set[Path]:
    claimed: set[Path] = set()

    for path in root.rglob("*"):
        if (
            path.is_file() and
            path.suffix.casefold() == ".vfl"
        ):
            claimed.update(
                parse_vfl_claims(path)
            )

    return claimed


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "BareFront multidisc library organiser "
            "READ-ONLY candidate"
        )
    )

    parser.add_argument(
        "--root",
        required=True,
        help="Resolved BareFront ROM root"
    )

    args = parser.parse_args()

    root = Path(args.root).resolve(strict=True)

    if not root.is_dir():
        print(
            f"ERROR: ROM root is not a directory: {root}",
            file=sys.stderr
        )
        return 2

    print(
        "============================================================"
    )
    print(
        "BAREFRONT MULTIDISC LIBRARY ORGANISER — DRY RUN"
    )
    print(
        "READ ONLY — THIS CANDIDATE HAS NO APPLY MODE"
    )
    print(
        "============================================================"
    )

    print()
    print(f"ROM root: {root}")

    writable = os.access(
        root,
        os.W_OK
    )

    print(
        "Filesystem writability: " +
        (
            "WRITABLE"
            if writable
            else "READ-ONLY / NOT WRITABLE"
        )
    )

    print()
    print("=== EXISTING PLAYLISTS ===")

    (
        playlists,
        verified_by_playlist,
        playlist_errors,
        playlist_claims,
    ) = collect_playlists(root)

    valid_playlist_count = 0
    playlist_error_count = 0

    for playlist in playlists:
        rel = relative_text(
            root,
            playlist
        )

        errors = playlist_errors.get(
            playlist,
            []
        )

        if errors:
            playlist_error_count += 1

            print()
            print(f"ERROR    {rel}")

            for error in errors:
                print(f"         {error}")

            continue

        valid_playlist_count += 1

        print(
            f"SKIPPED  {rel} "
            f"(valid existing playlist, "
            f"{len(verified_by_playlist[playlist])} media)"
        )

    if not playlists:
        print("None")

    claimed_by_m3u = set(
        playlist_claims.keys()
    )

    claimed_by_vfl = collect_vfl_claims(
        root
    )

    protected_media = (
        claimed_by_m3u |
        claimed_by_vfl
    )

    print()
    print("=== RAW MULTIDISC CANDIDATES ===")

    groups: dict[
        tuple[Path, str],
        list[DiscUnit]
    ] = defaultdict(list)

    cue_errors: list[
        tuple[Path, str]
    ] = []

    disc_like_unclaimed = 0

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue

        if path.suffix.casefold() not in MEDIA_EXTENSIONS:
            continue

        try:
            resolved = path.resolve(strict=True)
        except OSError:
            continue

        if resolved in protected_media:
            continue

        identity = disc_identity(path)

        if identity is None:
            continue

        disc_like_unclaimed += 1

        disc_number, base_name = identity

        dependencies: tuple[Path, ...] = ()

        if path.suffix.casefold() == ".cue":
            try:
                dependencies = parse_cue_dependencies(
                    path
                )
            except RuntimeError as error:
                cue_errors.append(
                    (path, str(error))
                )
                continue

        key = (
            path.parent.resolve(strict=True),
            normalise_name(base_name)
        )

        groups[key].append(
            DiscUnit(
                path=resolved,
                disc_number=disc_number,
                base_name=base_name,
                dependencies=dependencies,
            )
        )

    for cue, error in cue_errors:
        print()
        print(
            "ERROR    " +
            relative_text(root, cue)
        )
        print(f"         {error}")

    candidate_count = 0
    ambiguous_count = len(cue_errors)
    singleton_count = 0

    for (
        parent,
        normalised_base
    ), units in sorted(
        groups.items(),
        key=lambda item: (
            str(item[0][0]),
            item[0][1]
        )
    ):

        units.sort(
            key=lambda unit: (
                unit.disc_number,
                unit.path.name.casefold()
            )
        )

        display_base = units[0].base_name

        if len(units) < 2:
            singleton_count += 1
            continue

        numbers = [
            unit.disc_number
            for unit in units
        ]

        unique_numbers = sorted(
            set(numbers)
        )

        if len(unique_numbers) != len(numbers):
            ambiguous_count += 1

            print()
            print(
                "AMBIGUOUS " +
                relative_text(
                    root,
                    parent / display_base
                )
            )
            print(
                "          Duplicate disc number(s): " +
                ", ".join(
                    str(number)
                    for number in numbers
                )
            )
            continue

        expected_numbers = list(
            range(
                1,
                max(unique_numbers) + 1
            )
        )

        if unique_numbers != expected_numbers:
            ambiguous_count += 1

            print()
            print(
                "AMBIGUOUS " +
                relative_text(
                    root,
                    parent / display_base
                )
            )
            print(
                "          Disc sequence found: " +
                ", ".join(
                    str(number)
                    for number in unique_numbers
                )
            )
            print(
                "          Expected contiguous sequence: " +
                ", ".join(
                    str(number)
                    for number in expected_numbers
                )
            )
            continue

        suffixes = {
            unit.path.suffix.casefold()
            for unit in units
        }

        if len(suffixes) != 1:
            ambiguous_count += 1

            print()
            print(
                "AMBIGUOUS " +
                relative_text(
                    root,
                    parent / display_base
                )
            )
            print(
                "          Mixed disc image types: " +
                ", ".join(sorted(suffixes))
            )
            continue

        parent_name = normalise_name(
            parent.name
        )

        base_name = normalise_name(
            display_base
        )

        clean_base_name = normalise_name(
            remove_parenthetical_tags(
                display_base
            )
        )

        dedicated_folder = (
            parent_name == base_name or
            (
                clean_base_name and
                parent_name == clean_base_name
            )
        )

        if dedicated_folder:
            target_folder = parent
        else:
            target_folder = (
                parent /
                display_base
            )

            if target_folder.exists():
                ambiguous_count += 1

                print()
                print(
                    "AMBIGUOUS " +
                    relative_text(
                        root,
                        parent / display_base
                    )
                )
                print(
                    "          Target game folder already exists: " +
                    relative_text(
                        root,
                        target_folder
                    )
                )
                continue

        target_playlist = (
            target_folder /
            f"{display_base}.m3u"
        )

        if target_playlist.exists():
            ambiguous_count += 1

            print()
            print(
                "AMBIGUOUS " +
                relative_text(
                    root,
                    target_playlist
                )
            )
            print(
                "          Target playlist already exists"
            )
            continue

        candidate_count += 1

        print()
        print(
            "WOULD CREATE " +
            relative_text(
                root,
                target_playlist
            )
        )

        if dedicated_folder:
            print(
                "             Existing game folder retained"
            )
        else:
            print(
                "WOULD MKDIR  " +
                relative_text(
                    root,
                    target_folder
                )
            )

        move_files: set[Path] = set()

        for unit in units:
            print(
                f"             Disc {unit.disc_number}: "
                f"{relative_text(root, unit.path)}"
            )

            if not dedicated_folder:
                move_files.add(unit.path)

            for dependency in unit.dependencies:
                print(
                    "               + dependency: " +
                    relative_text(
                        root,
                        dependency
                    )
                )

                if not dedicated_folder:
                    move_files.add(
                        dependency
                    )

        if not dedicated_folder:
            for source in sorted(
                move_files,
                key=lambda path:
                    path.name.casefold()
            ):
                destination = (
                    target_folder /
                    source.name
                )

                print(
                    "WOULD MOVE   " +
                    relative_text(root, source) +
                    " -> " +
                    relative_text(root, destination)
                )

        print("PLAYLIST:")

        for unit in units:
            print(
                f"             {unit.path.name}"
            )

    if candidate_count == 0:
        print()
        print("No safe raw multidisc sets found.")

    print()
    print("=== SUMMARY ===")
    print(
        f"Existing valid playlists : "
        f"{valid_playlist_count}"
    )
    print(
        f"Existing playlist errors : "
        f"{playlist_error_count}"
    )
    print(
        f"Safe creation candidates : "
        f"{candidate_count}"
    )
    print(
        f"Ambiguous / errors        : "
        f"{ambiguous_count}"
    )
    print(
        f"Unpaired disc-like media  : "
        f"{singleton_count}"
    )
    print(
        f"Media protected by .m3u   : "
        f"{len(claimed_by_m3u)}"
    )
    print(
        f"Media protected by .vfl   : "
        f"{len(claimed_by_vfl)}"
    )

    print()
    print(
        "============================================================"
    )
    print(
        "DRY RUN COMPLETE — ROM LIBRARY UNCHANGED"
    )
    print(
        "============================================================"
    )

    return (
        1
        if (
            playlist_error_count or
            ambiguous_count
        )
        else 0
    )


if __name__ == "__main__":
    raise SystemExit(main())
