/** A `??=` compound assignment: a target that rewrites the operator's literal fails to parse it. */
class NullCoalescingAssign {

	public var x(default, null): Null<Int>;

	public function f(): Void {
		x ??= 1;
	}

}
