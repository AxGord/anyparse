package unit.dev;

import dev.ChangedMembers;
import utest.Assert;
import utest.Test;

/** What the members of a `hxq changed` report are read as: the names a file changed, or no names when the report cannot say. */
final class ChangedMembersTest extends Test {

	public function testADeclarationsFileNamesItsMembersWhateverTheSign(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'changed against main: 1 file(s) — declarations 1',
			'M src/a/B.hx  declarations  +9 -2',
			'    + import a.C;',
			'    + ',

			'    ~ FnMember:run  +3 -3',
			'    + FinalMember:LIMIT  1 line(s)',
			'    - VarMember:old  1 line(s), base',
			'    + TypedefDecl:Extra --nth 1  1 line(s)',
			''
		].join('\n'));
		Assert.same(['run', 'LIMIT', 'old'], said['src/a/B.hx']);
	}

	@:pin('control')
	@:killer('M-CHANGED-MEMBERS-NONMEMBER-NAMED')
	public function testAChangeThatIsNoMemberLeavesTheFileUnnamed(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Header.hx  declarations  +2 -1',
			'    ~ ClassForm:Header  +2 -1',
			'    ~ FnMember:run  +1 -1',
			'M src/a/Whole.hx  declarations  +2 -0',
			'    ~ TypedefDecl:Whole  +2 -0',
			'M src/a/Gone.hx  declarations  +0 -3',
			'    - ClassDecl:Gone  3 line(s), base',
			'M src/a/Cond.hx  declarations  +1 -1',
			'    - #if  1 line(s)',
			'M src/a/Order.hx  declarations  +2 -2',
			'    ~ (module)  +2 -2',
			'M src/a/Param.hx  declarations  +1 -0',
			'    + Required:arg  1 line(s)',
			''
		].join('\n'));
		for (file in ['Header', 'Whole', 'Gone', 'Cond', 'Order', 'Param']) {
			Assert.isTrue(said.exists('src/a/$file.hx'), file);
			Assert.isNull(said['src/a/$file.hx'], file);
		}
	}

	public function testAFileThatIsNotReadAsDeclarationsIsUnnamedAndAMovedFileIsListedByItsNewPath(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'A src/a/New.hx  new  +10 -0',
			'    + ClassDecl:New  9 line(s)',
			'M src/a/Renamed.hx  renamed  +1 -1',
			'    ~ x -> y',
			'R100 src/a/Moved.hx  <- src/a/Was.hx  declarations  +1 -1',
			'    ~ FnMember:run  +1 -1',
			'M docs/with space.hx  text  +1 -0',
			''
		].join('\n'));
		for (file in ['src/a/New.hx', 'src/a/Renamed.hx', 'docs/with space.hx']) {
			Assert.isTrue(said.exists(file), file);
			Assert.isNull(said[file], file);
		}
		Assert.same(['run'], said['src/a/Moved.hx']);
		Assert.isFalse(said.exists('src/a/Was.hx'));
	}

	public function testAFileOfImportsOnlyNamesNoMemberAndALayoutFileIsAbsent(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Imp.hx  imports',
			'M src/a/Lay.hx  layout',
			'    ~ FnMember:run  +1 -1',
			''
		].join('\n'));
		Assert.same([], said['src/a/Imp.hx']);
		Assert.isFalse(said.exists('src/a/Lay.hx'));
		Assert.isFalse(ChangedMembers.of('').keys().hasNext());
	}

	public function testAHeaderWhoseCommentsAloneChangedNamesNoMemberAndKeepsTheOthers(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Doc.hx  declarations  +1 -1',
			'    ~ ClassForm:Doc  +1 -1',
			'          ',
			'        - /** old doc */',
			'        + /** new doc */',
			'          @:keep',
			'          final class Doc {',
			'        ...',
			'M src/a/Mid.hx  declarations  +2 -2',
			'    ~ ClassForm:Mid  +1 -1',
			'        ...',
			'           * l1',
			'        -  * l3 old',
			'        +  * l3 new',
			'           * l4',
			'        ...',
			'    ~ FnMember:run  +1 -1',
			'        - 	trace(1);',
			'        + 	trace(2);',
			'M src/a/Gone.hx  declarations  +0 -2',
			'    ~ TypedefDecl:Gone  +0 -2',
			'        - // a note',
			'        - /** gone */',
			'          typedef Gone = {',
			''
		].join('\n'));
		Assert.same([], said['src/a/Doc.hx']);
		Assert.same(['run'], said['src/a/Mid.hx']);
		Assert.same([], said['src/a/Gone.hx']);
	}

	public function testAHeaderWhoseCodeChangedLeavesTheFileUnnamedWhateverItsComments(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Extends.hx  declarations  +1 -1',
			'    ~ ClassForm:Extends  +1 -1',
			'        ...',
			'          /** doc */',
			'        - final class Extends extends B {',
			'        + final class Extends extends C {',
			'        ...',
			'M src/a/Meta.hx  declarations  +2 -2',
			'    ~ ClassForm:Meta  +2 -2',
			'          ',
			'        - /** old doc */',
			'        - @:keep',
			'        + /** new doc */',
			'        + @:keep @:x',
			'          final class Meta {',
			'        ...',
			'M src/a/Shared.hx  declarations  +1 -1',
			'    ~ ClassForm:Shared  +1 -1',
			'        - /* old */ @:keep',
			'        + /* new */ @:keep',
			'          final class Shared {',
			''
		].join('\n'));
		for (file in ['Extends', 'Meta', 'Shared']) {
			Assert.isTrue(said.exists('src/a/$file.hx'), file);
			Assert.isNull(said['src/a/$file.hx'], file);
		}
	}

	public function testACodeChangeInALaterHunkIsNotHiddenByABlockCommentOpenedInAnEarlierOne(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/L.hx  declarations  +2 -2',
			'    ~ ClassDecl:L  +2 -2',
			'        ...',
			'          ',
			'          /**',
			'        -  * l1',
			'        +  * L1',
			'           * l2',
			'           * l3',
			'        ...',
			'          @:c',
			'          @:d',
			'        - class L extends B {',
			'        + class L extends C {',
			'          ',
			'          }',
			''
		].join('\n'));
		Assert.isTrue(said.exists('src/L.hx'));
		Assert.isNull(said['src/L.hx']);
	}

}
