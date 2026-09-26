package unit.query;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.CachingGrammarPlugin;
import anyparse.query.CanonicalEdit;
import anyparse.query.EditJournal;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

/** `EditJournal`: a span of a rewritten text placed in the text before, only through the edits recorded applying. */
@:nullSafety(Strict)
class EditJournalTest extends Test {

	@:pin('control') @:killer('M-JOURNAL-SHIFT')
	public function testUntouchedTextMapsByTheShiftOfTheEditsBefore(): Void {
		final before: String = 'head\nkeep\n';
		final after: String = 'new line\nhead\nkeep\n';
		final journal: EditJournal = journalOf(before, [{ span: new Span(0, 0), text: 'new line\n' }], after);
		Assert.same(Mapped(new Span(5, 9)), journal.back(before, after, spanOf(after, 'keep')));
	}

	@:pin('control') @:killer('M-JOURNAL-INTERIOR')
	public function testAMovedMemberHasNoCounterpart(): Void {
		// a reorder deletes a member where it was and inserts it elsewhere: nothing inside it maps, the rest does
		final before: String = 'a {x}\nb {y}\n';
		final after: String = 'b {y}\na {x}\n';
		final journal: EditJournal = journalOf(before, [
			{ span: new Span(0, 6), text: '' },
			{ span: new Span(12, 12), text: 'a {x}\n' }
		], after);
		Assert.same(Unmapped(EditJournal.UNMAPPED_REWRITTEN), journal.back(before, after, spanOf(after, 'a {x}')));
		Assert.same(Mapped(new Span(6, 11)), journal.back(before, after, spanOf(after, 'b {y}')));
	}

	@:pin('control') @:killer('M-JOURNAL-INTERIOR')
	public function testSwappedIdenticalBodiesKeepTheirOwnIdentity(): Void {
		// two members with the same body swapped: the text alone cannot tell them apart, the edits do
		final before: String = 'a {r}\nb {r}\n';
		final after: String = 'b {r}\na {r}\n';
		final journal: EditJournal = journalOf(before, [
			{ span: new Span(0, 6), text: '' },
			{ span: new Span(12, 12), text: 'a {r}\n' }
		], after);
		Assert.same(Mapped(new Span(9, 10)), journal.back(before, after, new Span(3, 4)));
		Assert.same(Unmapped(EditJournal.UNMAPPED_REWRITTEN), journal.back(before, after, new Span(9, 10)));
	}

	@:pin('control') @:killer('M-JOURNAL-SHIFT')
	public function testManyEditsStillMapExactly(): Void {
		// no diff to give up on: six hundred edits shift the last line by exactly their sum
		final lines: Array<String> = [for (i in 0...600) 'x$i'];
		final before: String = lines.join('\n') + '\ntail\n';
		final after: String = [for (i in 0...600) 'yy$i'].join('\n') + '\ntail\n';
		final edits: Array<{ span: Span, text: String }> = [];
		var at: Int = 0;
		for (l in lines) {
			edits.push({ span: new Span(at, at + 1), text: 'yy' });
			at += l.length + 1;
		}
		final journal: EditJournal = journalOf(before, edits, after);
		Assert.same(Mapped(spanOf(before, 'tail')), journal.back(before, after, spanOf(after, 'tail')));
		Assert.same(Unmapped(EditJournal.UNMAPPED_REWRITTEN), journal.back(before, after, spanOf(after, 'yy599')));
	}

	@:pin('control') @:killer('M-JOURNAL-AGREE')
	public function testHistoriesThatPlaceASpanApartDecline(): Void {
		final journal: EditJournal = new EditJournal();
		journal.record('aa', [{ span: new Span(0, 1), text: '' }], 'a');
		journal.record('aa', [{ span: new Span(1, 2), text: '' }], 'a');
		Assert.same(Unmapped(EditJournal.UNMAPPED_AMBIGUOUS), journal.back('aa', 'a', new Span(0, 1)));
	}

	@:pin('control') @:killer('M-JOURNAL-OPAQUE')
	public function testASettleBeyondWhitespaceMapsNothing(): Void {
		final journal: EditJournal = new EditJournal();
		journal.record('f(x)\nk\n', [{ span: new Span(3, 3), text: ':Int' }], 'f(x : Int)\nk\n');
		Assert.same(Mapped(new Span(5, 6)), journal.back('f(x)\nk\n', 'f(x : Int)\nk\n', new Span(11, 12)));
		journal.record('g\nk\n', [{ span: new Span(0, 1), text: 'h' }], 'i\nk\n');
		Assert.same(Unmapped(EditJournal.UNMAPPED_REWRITTEN), journal.back('g\nk\n', 'i\nk\n', new Span(2, 3)));
	}

	@:pin('control') @:killer('M-JOURNAL-RECORD-PATH')
	public function testNoRecordedHistoryMapsNothing(): Void {
		final journal: EditJournal = journalOf('a\n', [{ span: new Span(0, 0), text: 'b' }], 'ba\n');
		Assert.same(Unmapped(EditJournal.UNMAPPED_NO_HISTORY), journal.back('a\n', 'ca\n', new Span(1, 2)));
		Assert.same(Mapped(new Span(0, 1)), journal.back('a\n', 'ba\n', new Span(1, 2)));
	}

	@:pin('control') @:killer('M-JOURNAL-RECORD')
	public function testTheCanonicalizerRecordsWhatItSettled(): Void {
		final cached: CachingGrammarPlugin = new CachingGrammarPlugin(new HaxeQueryPlugin());
		final raw: String = 'class C {\n\tfunction a() {}\n\n\tfunction b() {\n\t\tvar v = 1;\n\t}\n}\n';
		final canon: String = switch CanonicalEdit.canonicalize(raw, [], true, cached) {
			case Ok(text, _): text;
			case Err(message): throw message;
		};
		cached.editJournal = new EditJournal();
		final at: Int = canon.indexOf('a()') + 3;
		final now: String = switch CanonicalEdit.canonicalize(canon, [{ span: new Span(at, at), text: ':Void' }], false, cached) {
			case Ok(text, _): text;
			case Err(message): throw message;
		};
		final journal: Null<EditJournal> = cached.editJournal;
		Assert.same(Mapped(spanOf(canon, 'var v = 1;')), journal?.back(canon, now, spanOf(now, 'var v = 1;')));
	}

	private static function journalOf(before: String, edits: Array<{ span: Span, text: String }>, after: String): EditJournal {
		final journal: EditJournal = new EditJournal();
		journal.record(before, edits, after);
		return journal;
	}

	private static function spanOf(text: String, part: String): Span {
		final at: Int = text.indexOf(part);
		return new Span(at, at + part.length);
	}

}
