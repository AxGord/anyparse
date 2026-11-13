package anyparse.macro;

#if macro
import haxe.macro.Expr;

/**
 * The one Star emission skeleton of the trivia writer: an instance is one Star's emit, holding the Star's `StarPlan`,
 * its element array and the trailing-trivia slots its pair struct synthesised. The tryparse, block and sep families
 * extend it with the inputs that really differ, and their builders read the plan and these fields directly instead of
 * a positional parameter list copied into a context record.
 */
class TriviaStarEmit<P: StarPlan> {

	private final _plan: P;
	private final _fieldAccess: Expr;
	private final _trailBBSlot: Expr;
	private final _trailLCSlot: Expr;
	private final _trailCloseSlot: Expr;
	private final _trailOpenSlot: Expr;
	private final _openText: String;
	private final _closeText: String;

	/**
	 * An absent slot reads as its empty value: no blank before the orphan trail, no comments, no cuddled comment. The
	 * delimiters are the Star's lead and trail literals, empty where the emit writes none of its own.
	 */
	private function new(plan: P, fieldAccess: Expr, slots: TrailSlots, openText: String, closeText: String) {
		_plan = plan;
		_fieldAccess = fieldAccess;
		_trailBBSlot = slots.trailBBAccess ?? macro false;
		_trailLCSlot = slots.trailLCAccess ?? macro ([]: Array<String>);
		_trailCloseSlot = slots.trailCloseAccess ?? macro (null: Null<String>);
		_trailOpenSlot = slots.trailOpenAccess ?? macro (null: Null<String>);
		_openText = openText;
		_closeText = closeText;
	}

	/** The trailing-slot locals a block or sep body reads, declared in the body's own scope as one statement. */
	private function trailSlotDecls(): Expr {
		return macro final _trailLC: Array<String> = $_trailLCSlot,
			_trailBB: Bool = $_trailBBSlot,
			_trailClose: Null<String> = $_trailCloseSlot,
			_trailOpen: Null<String> = $_trailOpenSlot;
	}

}
/** The trailing-trivia slot reads of a Star whose pair struct or enum ctor synthesised them; null where it did not. */
typedef TrailSlots = {
	final trailBBAccess: Null<Expr>;
	final trailLCAccess: Null<Expr>;
	final trailCloseAccess: Null<Expr>;
	final trailOpenAccess: Null<Expr>;
}
#end
