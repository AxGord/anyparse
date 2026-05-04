package anyparse.grammar.haxe;

/**
 * Helpers for the `HxMetadata` enum.
 *
 * `source(m)` extracts the textual form of a meta tag for AST-shape
 * unit tests — the pre-enum abstract had `to String` so test code
 * relied on `(meta : String)` casts. After the enum split, tests
 * either pattern-match on the variants directly (when they care about
 * the structural payload) or call `source()` to recover the source-
 * level appearance.
 *
 * For `PlainMeta(raw)`, returns the verbatim regex match.
 *
 * For structurally-parsed branches (e.g. `OverloadMeta`), the source
 * form must be reconstructed by the writer. Since unit tests rarely
 * need this and the writer's full Doc pipeline is heavy, those
 * branches throw — tests that inspect structural metas should switch
 * on the variant directly.
 */
class HxMetadataUtil {

	public static inline function source(m:HxMetadata):String {
		return switch m {
			case PlainMeta(raw): (raw : String);
			case OverloadMeta(_): throw 'HxMetadataUtil.source: structural OverloadMeta cannot be re-emitted as a String — switch on the variant directly';
		}
	}

}
