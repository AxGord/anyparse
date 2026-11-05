package unit.lowering;

/** A `@:re` terminal and its compiled scan, as `ScanMatchers.under` builds them. */
typedef ScanMatcher = {
	final name: String;
	final pattern: String;
	final scan: Null<(input:anyparse.runtime.Input, start:Int) -> Int>;
}
