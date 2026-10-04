#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import sys

from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path


ANALYSER = Path(__file__).resolve().with_name(
    "barefront_multidisc_core.py"
)


class InjectedFailure(RuntimeError):
    pass


@dataclass
class Plan:
    target_folder: Path
    target_playlist: Path
    dedicated_folder: bool
    units: list
    move_sources: list[Path]


def load_analyser():
    spec = importlib.util.spec_from_file_location(
        "bf_multidisc_analyser",
        ANALYSER
    )

    if spec is None or spec.loader is None:
        raise RuntimeError(
            "Cannot load dry-run analyser"
        )

    module = importlib.util.module_from_spec(spec)

    # dataclasses expects the module to exist here
    # while class decorators are evaluated.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    return module


bf = load_analyser()


def rel(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def build_plans(root: Path):
    (
        playlists,
        verified_by_playlist,
        playlist_errors,
        playlist_claims,
    ) = bf.collect_playlists(root)

    issues: list[str] = []

    for playlist in playlists:
        for error in playlist_errors.get(
            playlist,
            []
        ):
            issues.append(
                f"{rel(root, playlist)}: {error}"
            )

    claimed_by_m3u = set(
        playlist_claims.keys()
    )

    claimed_by_vfl = bf.collect_vfl_claims(
        root
    )

    protected = (
        claimed_by_m3u |
        claimed_by_vfl
    )

    groups = defaultdict(list)

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue

        if (
            path.suffix.casefold()
            not in bf.MEDIA_EXTENSIONS
        ):
            continue

        resolved = path.resolve(strict=True)

        if resolved in protected:
            continue

        identity = bf.disc_identity(path)

        if identity is None:
            continue

        number, base = identity
        dependencies = ()

        if path.suffix.casefold() == ".cue":
            try:
                dependencies = (
                    bf.parse_cue_dependencies(path)
                )
            except RuntimeError as error:
                issues.append(
                    f"{rel(root, path)}: {error}"
                )
                continue

        key = (
            path.parent.resolve(strict=True),
            bf.normalise_name(base)
        )

        groups[key].append(
            bf.DiscUnit(
                path=resolved,
                disc_number=number,
                base_name=base,
                dependencies=dependencies,
            )
        )

    plans: list[Plan] = []

    for (parent, _), units in sorted(
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

        # A lone "Disc 1" is not enough evidence
        # to call something multidisc.
        if len(units) < 2:
            continue

        display_base = units[0].base_name

        numbers = [
            unit.disc_number
            for unit in units
        ]

        unique = sorted(set(numbers))

        if len(unique) != len(numbers):
            issues.append(
                f"{rel(root, parent / display_base)}: "
                "duplicate disc number(s)"
            )
            continue

        expected = list(
            range(1, max(unique) + 1)
        )

        if unique != expected:
            issues.append(
                f"{rel(root, parent / display_base)}: "
                f"gapped disc sequence {unique}"
            )
            continue

        suffixes = {
            unit.path.suffix.casefold()
            for unit in units
        }

        if len(suffixes) != 1:
            issues.append(
                f"{rel(root, parent / display_base)}: "
                "mixed disc image types"
            )
            continue

        parent_name = bf.normalise_name(
            parent.name
        )

        base_name = bf.normalise_name(
            display_base
        )

        clean_base = bf.normalise_name(
            bf.remove_parenthetical_tags(
                display_base
            )
        )

        dedicated = (
            parent_name == base_name or
            (
                clean_base and
                parent_name == clean_base
            )
        )

        if dedicated:
            target_folder = parent
        else:
            target_folder = (
                parent /
                display_base
            )

            if target_folder.exists():
                issues.append(
                    f"{rel(root, target_folder)}: "
                    "target game folder already exists"
                )
                continue

        playlist = (
            target_folder /
            f"{display_base}.m3u"
        )

        if playlist.exists():
            issues.append(
                f"{rel(root, playlist)}: "
                "target playlist already exists"
            )
            continue

        move_sources: list[Path] = []

        if not dedicated:
            seen: set[Path] = set()

            for unit in units:
                candidates = [
                    unit.path,
                    *unit.dependencies,
                ]

                for source in candidates:
                    if source in seen:
                        continue

                    seen.add(source)
                    move_sources.append(source)

        plans.append(
            Plan(
                target_folder=target_folder,
                target_playlist=playlist,
                dedicated_folder=dedicated,
                units=units,
                move_sources=move_sources,
            )
        )

    return plans, issues


def preflight(
    root: Path,
    plans: list[Plan]
):
    seen_sources: set[Path] = set()
    seen_destinations: set[Path] = set()

    for plan in plans:
        if not bf.inside(
            root,
            plan.target_folder.resolve(
                strict=False
            )
        ):
            raise RuntimeError(
                "Target folder escapes ROM root"
            )

        if plan.target_playlist.exists():
            raise RuntimeError(
                "Target playlist already exists: " +
                rel(root, plan.target_playlist)
            )

        if plan.dedicated_folder:
            if not plan.target_folder.is_dir():
                raise RuntimeError(
                    "Existing game folder vanished: " +
                    rel(root, plan.target_folder)
                )
        else:
            if plan.target_folder.exists():
                raise RuntimeError(
                    "Target game folder appeared: " +
                    rel(root, plan.target_folder)
                )

            parent_device = (
                plan.target_folder.parent.stat().st_dev
            )

            for source in plan.move_sources:
                if source.stat().st_dev != parent_device:
                    raise RuntimeError(
                        "Cross-filesystem move refused: " +
                        rel(root, source)
                    )

        for source in plan.move_sources:
            if not source.is_file():
                raise RuntimeError(
                    "Move source missing: " +
                    rel(root, source)
                )

            if source in seen_sources:
                raise RuntimeError(
                    "Move source claimed twice: " +
                    rel(root, source)
                )

            seen_sources.add(source)

            destination = (
                plan.target_folder /
                source.name
            )

            if (
                destination.exists() or
                destination in seen_destinations
            ):
                raise RuntimeError(
                    "Move destination conflict: " +
                    rel(root, destination)
                )

            seen_destinations.add(
                destination
            )


def playlist_bytes(plan: Plan) -> bytes:
    lines = [
        "# BareFront canonical multidisc playlist"
    ]

    for unit in plan.units:
        lines.append(
            unit.path.name
        )

    return (
        "\n".join(lines) + "\n"
    ).encode("utf-8")


def apply_transaction(
    root: Path,
    plans: list[Plan],
    inject_after: int | None
):
    journal: list[tuple] = []
    action_count = 0

    def mutation_complete():
        nonlocal action_count

        action_count += 1

        if (
            inject_after is not None and
            action_count >= inject_after
        ):
            raise InjectedFailure(
                "Injected failure after "
                f"mutation {action_count}"
            )

    def rollback():
        failures: list[str] = []

        for entry in reversed(journal):
            kind = entry[0]

            try:
                if kind == "remove-file":
                    path = entry[1]

                    if path.exists():
                        path.unlink()

                elif kind == "move-back":
                    destination = entry[1]
                    source = entry[2]

                    if destination.exists():
                        if source.exists():
                            raise RuntimeError(
                                "original path unexpectedly exists"
                            )

                        destination.rename(source)

                elif kind == "remove-dir":
                    directory = entry[1]

                    if directory.exists():
                        directory.rmdir()

            except Exception as error:
                failures.append(
                    f"{kind}: {error}"
                )

        if failures:
            raise RuntimeError(
                "ROLLBACK FAILURE: " +
                "; ".join(failures)
            )

    try:
        for plan in plans:
            print()
            print(
                "APPLY     " +
                rel(root, plan.target_playlist)
            )

            if not plan.dedicated_folder:
                plan.target_folder.mkdir()

                journal.append(
                    (
                        "remove-dir",
                        plan.target_folder,
                    )
                )

                print(
                    "MKDIR     " +
                    rel(root, plan.target_folder)
                )

                mutation_complete()

                for source in plan.move_sources:
                    destination = (
                        plan.target_folder /
                        source.name
                    )

                    source.rename(destination)

                    journal.append(
                        (
                            "move-back",
                            destination,
                            source,
                        )
                    )

                    print(
                        "MOVE      " +
                        rel(root, source) +
                        " -> " +
                        rel(root, destination)
                    )

                    mutation_complete()

            temporary = (
                plan.target_playlist.parent /
                (
                    "." +
                    plan.target_playlist.name +
                    ".barefront-tmp-" +
                    str(os.getpid())
                )
            )

            if temporary.exists():
                raise RuntimeError(
                    "Temporary playlist already exists"
                )

            try:
                with temporary.open("xb") as handle:
                    handle.write(
                        playlist_bytes(plan)
                    )
                    handle.flush()
                    os.fsync(handle.fileno())

                os.rename(
                    temporary,
                    plan.target_playlist
                )

            finally:
                if temporary.exists():
                    temporary.unlink()

            journal.append(
                (
                    "remove-file",
                    plan.target_playlist,
                )
            )

            print(
                "CREATE    " +
                rel(root, plan.target_playlist)
            )

            mutation_complete()

    except Exception:
        print()
        print(
            "APPLY FAILED — ROLLING BACK"
        )

        rollback()

        print(
            "ROLLBACK COMPLETE"
        )

        raise


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--root",
        required=True
    )

    parser.add_argument(
        "--apply",
        action="store_true"
    )

    parser.add_argument(
        "--inject-failure-after",
        type=int
    )

    args = parser.parse_args()

    root = Path(
        args.root
    ).resolve(strict=True)

    if not root.is_dir():
        print(
            "ERROR: ROM root is not a directory",
            file=sys.stderr
        )
        return 2

    plans, issues = build_plans(root)

    print(
        "============================================================"
    )
    print(
        "BAREFRONT MULTIDISC ORGANISER — "
        + (
            "APPLY"
            if args.apply
            else "DRY RUN"
        )
    )
    print(
        "============================================================"
    )

    print()
    print(f"ROM root: {root}")
    print(f"Safe plans: {len(plans)}")
    print(f"Blocking issues: {len(issues)}")

    if issues:
        print()
        print("=== BLOCKING ISSUES ===")

        for issue in issues:
            print("AMBIGUOUS " + issue)

    print()
    print("=== SAFE PLANS ===")

    if not plans:
        print("No changes required.")

    for plan in plans:
        print()
        print(
            "PLAYLIST  " +
            rel(root, plan.target_playlist)
        )

        if plan.dedicated_folder:
            print(
                "          Existing game folder retained"
            )
        else:
            print(
                "MKDIR     " +
                rel(root, plan.target_folder)
            )

            for source in plan.move_sources:
                print(
                    "MOVE      " +
                    rel(root, source) +
                    " -> " +
                    rel(
                        root,
                        plan.target_folder /
                        source.name
                    )
                )

        for unit in plan.units:
            print(
                f"          Disc {unit.disc_number}: "
                f"{unit.path.name}"
            )

    if not args.apply:
        print()
        print(
            "DRY RUN COMPLETE — NO CHANGES"
        )

        return (
            1
            if issues
            else 0
        )

    if issues:
        print()
        print(
            "REFUSED: apply requires a zero-ambiguity library"
        )
        return 3

    if not os.access(root, os.W_OK):
        print()
        print(
            "REFUSED: active ROM root is not writable"
        )
        return 4

    if not plans:
        print()
        print(
            "APPLY COMPLETE — NOTHING TO DO"
        )
        return 0

    try:
        preflight(
            root,
            plans
        )

        apply_transaction(
            root,
            plans,
            args.inject_failure_after
        )

    except InjectedFailure as error:
        print()
        print(f"EXPECTED TEST FAILURE: {error}")
        return 97

    except Exception as error:
        print()
        print(f"ERROR: {error}")
        return 2

    print()
    print(
        "APPLY COMPLETE — TRANSACTION COMMITTED"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
