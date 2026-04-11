package anyparse.runtime;

/**
 * Pluggable cache used by packrat-style generated parsers to memoize
 * rule results by `(rule, position)`. Phase 1 ships `NoOpCache` as the
 * default implementation — it performs zero memoization and has zero
 * overhead. Real caches are plugged in when incremental parsing lands.
 *
 * The interface is deliberately small. Keys are opaque strings produced
 * by generated code; values are whatever the rule returned. The
 * `Dynamic` on values is intentional — each generated parser knows the
 * concrete type it stores and cast is cheap in Haxe.
 */
interface ParseCache {
	function get(key:String):Null<Dynamic>;

	function set(key:String, value:Dynamic):Void;

	function clear():Void;
}
