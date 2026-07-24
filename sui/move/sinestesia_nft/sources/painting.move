/// Sinestesia — a painting created *live* from a singer's voice, minted onchain
/// with provenance proving it was made in that exact moment.
///
/// The `provenance_hash` is a SHA-256 over the performance's transcript, the
/// Director model's prompts and the timestamps, computed off-chain at song end.
/// The NFT therefore is not just an image: it is proof of the live moment that
/// produced it.
module sinestesia_nft::painting;

use std::string::{Self, String};
use sui::display;
use sui::event;
use sui::package;

/// A minted live painting.
public struct Painting has key, store {
    id: UID,
    /// Human title, e.g. "Sinestesia — Ocean of You".
    name: String,
    /// The song performed.
    song: String,
    /// Performer / act name.
    artist: String,
    /// Where the image bytes live (a Walrus aggregator URL).
    image_url: String,
    /// The raw Walrus blob id, for verification independent of any gateway.
    walrus_blob_id: String,
    /// SHA-256 (hex) of transcript + Director prompts + timestamps.
    provenance_hash: String,
    /// Unix ms when the performance ended.
    created_at_ms: u64,
    /// Venue / event, e.g. "ETHGlobal Lisbon 2026".
    venue: String,
}

/// One-time witness for claiming the `Publisher` and setting up Display.
public struct PAINTING has drop {}

/// Emitted on every mint so indexers and the live UI can react instantly.
public struct PaintingMinted has copy, drop {
    id: ID,
    song: String,
    provenance_hash: String,
    minted_to: address,
}

fun init(otw: PAINTING, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    let mut disp = display::new<Painting>(&publisher, ctx);
    disp.add(b"name".to_string(), b"{name}".to_string());
    disp.add(b"image_url".to_string(), b"{image_url}".to_string());
    disp.add(
        b"description".to_string(),
        b"Painted live from \"{song}\" by {artist} at {venue}. Provenance {provenance_hash}.".to_string(),
    );
    disp.add(b"project_url".to_string(), b"https://sinestesia.art".to_string());
    disp.update_version();

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(disp, ctx.sender());
}

/// Mint a live painting and send it to `recipient`.
///
/// Byte-vector params are UTF-8 strings; the client passes them via `tx.pure`.
public entry fun mint(
    name: vector<u8>,
    song: vector<u8>,
    artist: vector<u8>,
    image_url: vector<u8>,
    walrus_blob_id: vector<u8>,
    provenance_hash: vector<u8>,
    created_at_ms: u64,
    venue: vector<u8>,
    recipient: address,
    ctx: &mut TxContext,
) {
    let painting = Painting {
        id: object::new(ctx),
        name: string::utf8(name),
        song: string::utf8(song),
        artist: string::utf8(artist),
        image_url: string::utf8(image_url),
        walrus_blob_id: string::utf8(walrus_blob_id),
        provenance_hash: string::utf8(provenance_hash),
        created_at_ms,
        venue: string::utf8(venue),
    };

    event::emit(PaintingMinted {
        id: object::id(&painting),
        song: painting.song,
        provenance_hash: painting.provenance_hash,
        minted_to: recipient,
    });

    transfer::public_transfer(painting, recipient);
}

#[test_only]
public fun destroy_for_testing(p: Painting) {
    let Painting { id, .. } = p;
    id.delete();
}
