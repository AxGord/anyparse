package unit.dev;

import dev.QueueFile;
import utest.Assert;
import utest.Test;

/** `QueueFile`: the queue file's `tasks:` list read into lines, over a fixture in the shape the queue tools write. */
@:nullSafety(Strict)
final class QueueFileTest extends Test {

	private static final QUEUE: String = [
		'header: not a task',
		'tasks:',
		'  - id: A-1',
		'    status: done',
		'    owner: Own',
		'    ended: 2026-11-08',
		'    base: abc123',
		'    touches: [ src/a, test/b ]',
		'    after: [ X-1, X-2 ]',
		'    text: |-',
		'      first line',
		'        indented second',
		'',
		'      third after a blank',
		'    notes:',
		'      - from: parent',
		'        date: 2026-11-09',
		'        text: "quoted \\"note\\" here"',
		'      - from: worker',
		'        date: 2026-11-10',
		'        text: plain note',
		'  - id: B-2',
		'    status: pending',
		'    text: |-',
		'      only',
		''
	].join('\n');

	@:pin('control')
	@:killer('M-QUEUEFILE-LIST-ITEMS')
	public function testAFlowListIsReadItemByItem(): Void {
		final line: Null<QueueLine> = QueueFile.find(QUEUE, 'A-1');
		Assert.same(['src/a', 'test/b'], line?.touches);
		Assert.same(['X-1', 'X-2'], line?.after);
	}

	@:pin('control')
	@:killer('M-QUEUEFILE-TEXT-UNINDENT')
	public function testABlockTextKeepsItsLinesAndRelativeIndent(): Void {
		Assert.equals('first line\n  indented second\n\nthird after a blank', QueueFile.find(QUEUE, 'A-1')?.text);
	}

	@:pin('control')
	@:killer('M-QUEUEFILE-SCALARS')
	public function testScalarFieldsAreReadAsWritten(): Void {
		final line: Null<QueueLine> = QueueFile.find(QUEUE, 'A-1');
		Assert.equals('done', line?.status);
		Assert.equals('Own', line?.owner);
		Assert.equals('2026-11-08', line?.ended);
		Assert.equals('abc123', line?.base);
	}

	@:pin('control')
	@:killer('M-QUEUEFILE-NOTE-QUOTES')
	public function testANoteReadsItsFieldsAndDecodesAQuotedText(): Void {
		final notes: Array<QueueNote> = QueueFile.find(QUEUE, 'A-1')?.notes ?? [];
		Assert.equals(2, notes.length);
		Assert.equals('parent', notes[0].from);
		Assert.equals('2026-11-09', notes[0].date);
		Assert.equals('quoted "note" here', notes[0].text);
		Assert.equals('plain note', notes[1].text);
	}

	@:pin('control')
	@:killer('M-QUEUEFILE-ENTRY-BOUNDARY')
	public function testAFieldTheLineLacksIsEmptyAndTheNextLineIsItsOwn(): Void {
		final line: Null<QueueLine> = QueueFile.find(QUEUE, 'B-2');
		Assert.equals('pending', line?.status);
		Assert.equals('only', line?.text);
		Assert.equals('', line?.owner);
		Assert.equals(0, line?.touches.length);
		Assert.equals(0, line?.notes.length);
		Assert.equals(2, QueueFile.read(QUEUE).length);
	}

	public function testAnUnknownIdIsNull(): Void {
		Assert.isNull(QueueFile.find(QUEUE, 'C-3'));
	}

	public function testAFileWithoutATasksListHasNoLines(): Void {
		Assert.equals(0, QueueFile.read('  - id: A-1\n    status: done\n').length);
	}

}
