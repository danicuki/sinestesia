/// Sinestesia — a painting created *live* from a singer's voice, minted onchain
/// with provenance proving it was made in that exact moment.
///
/// Supply model (one per performed song):
///   * a **master** 1/1 (edition 0) minted to the artist — the original;
///   * **open-edition prints** (edition 1..N) that anyone in the room can claim
///     for free (they pay only gas) during the claim window.
///
/// A shared `Release` object holds the canonical metadata and the print
/// counter, so prints are numbered and provably reference the same performance.
///
/// The `provenance_hash` is a SHA-256 over the performance transcript, the
/// Director model's prompts and the timestamps, computed off-chain at song end:
/// the NFT is not just an image, it is proof of the live moment that made it.
module sinestesia_nft::painting;

use std::string::{Self, String};
use sui::display;
use sui::event;
use sui::package;

const E_CLOSED: u64 = 0;
const E_NOT_CREATOR: u64 = 1;

/// One-time witness for Display setup.
public struct PAINTING has drop {}

/// Shared, one per song: canonical metadata + open-edition print counter.
public struct Release has key {
    id: UID,
    song: String,
    artist: String,
    venue: String,
    image_url: String,
    walrus_blob_id: String,
    provenance_hash: String,
    /// Compact JSON of the performance-derived rarity traits.
    traits: String,
    created_at_ms: u64,
    creator: address,
    prints_minted: u64,
    /// Artist can close the claim window; prints can only be claimed while open.
    open: bool,
}

/// The NFT. `edition` 0 with `is_master = true` is the 1/1; 1..N are prints.
public struct Painting has key, store {
    id: UID,
    name: String,
    song: String,
    artist: String,
    venue: String,
    image_url: String,
    walrus_blob_id: String,
    provenance_hash: String,
    traits: String,
    created_at_ms: u64,
    edition: u64,
    is_master: bool,
    /// Back-reference to the Release this belongs to.
    release: ID,
}

public struct ReleaseCreated has copy, drop {
    release: ID,
    song: String,
    master: ID,
    creator: address,
}

public struct PrintClaimed has copy, drop {
    release: ID,
    edition: u64,
    minted_to: address,
}

fun init(otw: PAINTING, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut disp = display::new<Painting>(&publisher, ctx);
    disp.add(b"name".to_string(), b"{name}".to_string());
    disp.add(b"image_url".to_string(), b"{image_url}".to_string());
    disp.add(
        b"description".to_string(),
        b"Edition #{edition}, painted live from \"{song}\" by {artist} at {venue}. Provenance {provenance_hash}.".to_string(),
    );
    disp.add(b"project_url".to_string(), b"https://sinestesia.art".to_string());
    disp.update_version();

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(disp, ctx.sender());
}

fun new_painting(
    r: &Release,
    edition: u64,
    is_master: bool,
    ctx: &mut TxContext,
): Painting {
    let mut name = string::utf8(b"Sinestesia \xE2\x80\x94 "); // "Sinestesia — "
    name.append(r.song);
    Painting {
        id: object::new(ctx),
        name,
        song: r.song,
        artist: r.artist,
        venue: r.venue,
        image_url: r.image_url,
        walrus_blob_id: r.walrus_blob_id,
        provenance_hash: r.provenance_hash,
        traits: r.traits,
        created_at_ms: r.created_at_ms,
        edition,
        is_master,
        release: object::id(r),
    }
}

/// Artist creates the release: mints the master 1/1 to themselves and shares
/// the `Release` so the audience can claim prints.
public fun create_release(
    song: vector<u8>,
    artist: vector<u8>,
    venue: vector<u8>,
    image_url: vector<u8>,
    walrus_blob_id: vector<u8>,
    provenance_hash: vector<u8>,
    traits: vector<u8>,
    created_at_ms: u64,
    ctx: &mut TxContext,
) {
    let creator = ctx.sender();
    let release = Release {
        id: object::new(ctx),
        song: string::utf8(song),
        artist: string::utf8(artist),
        venue: string::utf8(venue),
        image_url: string::utf8(image_url),
        walrus_blob_id: string::utf8(walrus_blob_id),
        provenance_hash: string::utf8(provenance_hash),
        traits: string::utf8(traits),
        created_at_ms,
        creator,
        prints_minted: 0,
        open: true,
    };

    let master = new_painting(&release, 0, true, ctx);
    let master_id = object::id(&master);

    event::emit(ReleaseCreated {
        release: object::id(&release),
        song: release.song,
        master: master_id,
        creator,
    });

    transfer::public_transfer(master, creator);
    transfer::share_object(release);
}

/// Anyone claims a free open-edition print (pays only gas). Sent to the caller.
public fun claim_print(release: &mut Release, ctx: &mut TxContext) {
    assert!(release.open, E_CLOSED);
    release.prints_minted = release.prints_minted + 1;
    let edition = release.prints_minted;

    let print = new_painting(release, edition, false, ctx);

    event::emit(PrintClaimed {
        release: object::id(release),
        edition,
        minted_to: ctx.sender(),
    });

    transfer::public_transfer(print, ctx.sender());
}

/// Artist opens/closes the claim window.
public fun set_open(release: &mut Release, open: bool, ctx: &TxContext) {
    assert!(ctx.sender() == release.creator, E_NOT_CREATOR);
    release.open = open;
}

/// How many prints have been claimed so far.
public fun prints_minted(release: &Release): u64 {
    release.prints_minted
}

#[test_only]
public fun destroy_for_testing(p: Painting) {
    let Painting { id, .. } = p;
    id.delete();
}
