/** An `#else` straight after an operand: a target whose operator loop takes `#` for an operator eats the directive. */
class ElseAfterOperand {

	public var x(default, null): Null<Int>;

	public function f(): Void {
		x = #if js 1 #else 2 #end;
	}

}
