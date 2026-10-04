#pragma once

#include <filesystem>
#include <string>
#include <system_error>

namespace bfcontent
{

namespace fs = std::filesystem;


struct Source
{
    std::string name;
    fs::path root;
};


// --------------------------------------------------
// Portable source contract
//
// A BareFront content source contains:
//
//   <source>/roms/
//   <source>/bios/
//
// The source itself may be local, removable or
// network-backed.  Runtime activation never writes
// into the selected source.
// --------------------------------------------------

inline bool validSource(
    const fs::path& root)
{
    std::error_code error;

    const bool romsValid =
        fs::is_directory(
            root / "roms",
            error
        );

    if (error)
        return false;

    const bool biosValid =
        fs::is_directory(
            root / "bios",
            error
        );

    return
        !error &&
        romsValid &&
        biosValid;
}


// --------------------------------------------------
// Check one BareFront-managed symlink.
//
// Canonical ROM / BIOS links deliberately remain
// fixed for the lifetime of the installation:
//
//   roms -> content/active/roms
//   bios -> content/active/bios
//
// Source switching changes content/active only.
// --------------------------------------------------

inline bool managedLinkMatches(
    const fs::path& link,
    const fs::path& expectedTarget)
{
    std::error_code error;

    const fs::file_status status =
        fs::symlink_status(
            link,
            error
        );

    if (error ||
        !fs::is_symlink(status))
    {
        return false;
    }

    const fs::path actualTarget =
        fs::read_symlink(
            link,
            error
        );

    return
        !error &&
        actualTarget ==
            expectedTarget;
}


// --------------------------------------------------
// Runtime layout validation.
//
// Runtime code NEVER converts legacy directories,
// repairs partial migrations or replaces ordinary
// files/directories.
//
// Installation / migration owns that job.
// --------------------------------------------------

inline bool managedLayoutReady(
    const fs::path& barefrontRoot)
{
    if (!managedLinkMatches(
            barefrontRoot / "roms",
            fs::path("content/active/roms")))
    {
        return false;
    }

    if (!managedLinkMatches(
            barefrontRoot / "bios",
            fs::path("content/active/bios")))
    {
        return false;
    }

    std::error_code error;

    const fs::file_status activeStatus =
        fs::symlink_status(
            barefrontRoot /
                "content" /
                "active",
            error
        );

    return
        !error &&
        fs::is_symlink(
            activeStatus
        );
}


// --------------------------------------------------
// Temporary selector safety.
//
// A stale BareFront-owned .active.new symlink may be
// removed after an interrupted activation.
//
// An ordinary file or directory is NEVER removed.
// --------------------------------------------------

inline bool prepareTemporarySelector(
    const fs::path& temporary)
{
    std::error_code error;

    const fs::file_status status =
        fs::symlink_status(
            temporary,
            error
        );

    if (error)
    {
        return
            error ==
            std::errc::no_such_file_or_directory;
    }

    if (status.type() ==
        fs::file_type::not_found)
    {
        return true;
    }

    if (!fs::is_symlink(status))
        return false;

    fs::remove(
        temporary,
        error
    );

    return !error;
}


// --------------------------------------------------
// Atomically select one source.
//
// The selected source is validated first.
//
// A new content/active symlink is built alongside the
// old selector and renamed over it.  ROM and BIOS
// therefore change together as one selector operation.
//
// The canonical roms / bios symlinks never change.
// --------------------------------------------------

inline bool activate(
    const fs::path& barefrontRoot,
    const Source& source)
{
    if (!validSource(
            source.root))
    {
        return false;
    }

    if (!managedLayoutReady(
            barefrontRoot))
    {
        return false;
    }

    const fs::path contentDirectory =
        barefrontRoot /
        "content";

    const fs::path active =
        contentDirectory /
        "active";

    const fs::path temporary =
        contentDirectory /
        ".active.new";

    if (!prepareTemporarySelector(
            temporary))
    {
        return false;
    }

    std::error_code error;

    const fs::path absoluteSource =
        fs::absolute(
            source.root,
            error
        );

    if (error)
        return false;

    fs::create_symlink(
        absoluteSource,
        temporary,
        error
    );

    if (error)
        return false;

    fs::rename(
        temporary,
        active,
        error
    );

    if (error)
    {
        std::error_code cleanupError;

        fs::remove(
            temporary,
            cleanupError
        );

        return false;
    }

    return true;
}


} // namespace bfcontent
