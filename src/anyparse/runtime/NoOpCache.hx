package anyparse.runtime;

/**
 * Default `ParseCache` that performs no caching at all. `get` always
 * returns `null`, `set` and `clear` are no-ops. Used by every `Parser`
 * instance by default; installed only where a real cache is needed.
 *
 * Singleton because the object has no state and sharing one instance
 * avoids per-parse allocation.
 */
@:nullSafety(Strict)
final class NoOpCache implements ParseCache {

	public static final instance:NoOpCache = new NoOpCache();

	private function new() {}

	public inline function get(key:String):Null<Dynamic> {
		return null;
	}

	public inline function set(key:String, value:Dynamic):Void {}

	public inline function clear():Void {}
}
