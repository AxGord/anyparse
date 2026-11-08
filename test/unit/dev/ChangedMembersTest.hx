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

	public function testAMemberWhoseCommentsAloneChangedIsNoChangeAndOneWhoseCodeChangedIs(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Doc.hx  declarations  +2 -2',
			'    ~ FnMember:docOnly  +2 -2',
			'        ...',
			'          \t * one',
			'        - \t * three',
			'        + \t * THREE',
			'          \t * four',
			'        ...',
			'          \tpublic function docOnly():Int {',
			'          \t\tfinal x:Int = 1;',
			'        - \t\t// note',
			'        + \t\t// NOTE',
			'          \t\treturn x;',
			'    ~ FnMember:edited  +2 -2',
			'        - \t/** old */',
			'        - \t\treturn 1;',
			'        + \t/** new */',
			'        + \t\treturn 2;',
			'    + FnMember:added  3 line(s)',
			'    ~ VarMember:bare  +1 -1',
			'    ~ FnMember:inline  +1 -1',
			'        - \t\treturn 1; // a',
			'        + \t\treturn 1; // b',
			'M src/a/Only.hx  declarations  +1 -1',
			'    ~ FnMember:docOnly  +1 -1',
			'        - \t/** old */',
			'        + \t/** new */',
			''
		].join('\n'));
		Assert.same(
			['edited', 'added', 'bare', 'inline'],
			said['src/a/Doc.hx'], 'doc-only is dropped; code, a new member and a row without lines stay'
		);
		Assert.same([], said['src/a/Only.hx'], 'a file of doc-only members names none and is not unnamed');
	}

	public function testAContinuationLineOfCodeIsNotTakenForADocLine(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Star.hx  declarations  +1 -1',
			'    ~ FnMember:wrapped  +1 -1',
			'        ...',
			'          \t\tfinal x:Int = a',
			'        - \t\t\t* 2;',
			'        + \t\t\t* 3;',
			'          \t\treturn x;',
			''
		].join('\n'));
		Assert.same(['wrapped'], said['src/a/Star.hx']);
	}

	public function testADeletedFileNamesNoMemberAndLeavesTheFileBeforeItAlone(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Kept.hx  declarations  +1 -1',
			'    ~ FnMember:run  +1 -1',
			'D src/a/Gone.hx  deleted  +0 -9',
			'    - ClassForm:Gone  9 line(s), base',
			'    - FnMember:run  3 line(s), base',
			''
		].join('\n'));
		Assert.same(['run'], said['src/a/Kept.hx']);
		Assert.isTrue(said.exists('src/a/Gone.hx'));
		Assert.same([], said['src/a/Gone.hx']);
	}

	@:pin('control')
	@:killer('M-CHANGED-MEMBERS-STRING-LINE-COMMENT')
	public function testALineThatOpensAsACommentInsideAMultiLineStringIsCode(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Str.hx  declarations  +2 -2',
			'    ~ FnMember:run  +2 -2',
			'        - \t\tfinal s = \'one',
			'        - /* old',
			'        - \';',
			'        + \t\tfinal s = \'one',
			'        + /* new',
			'        + \';',
			''
		].join('\n'));
		Assert.same(['run'], said['src/a/Str.hx']);
	}

	@:pin('control')
	@:killer('M-CHANGED-MEMBERS-LEADING-DOC-STAR')
	public function testAHunkThatOpensInsideADocCommentWithAnApostropheStillSeesTheCodeChange(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Open.hx  declarations  +1 -1',
			'    ~ FnMember:run  +1 -1',
			'          \t * don\'t touch',
			'          \t */',
			'          public function run() {',
			'          final glob = \'src/*.hx\';',
			'        - before();',
			'        + after();',
			'          }',
			''
		].join('\n'));
		Assert.same(['run'], said['src/a/Open.hx']);
	}

	@:pin('control')
	@:killer('M-CHANGED-MEMBERS-LEADING-DOC-STAR')
	public function testAHunkThatOpensInsideADocCommentWithAnApostropheStillSeesACommentOnlyChange(): Void {
		final said: Map<String, Null<Array<String>>> = ChangedMembers.of([
			'M src/a/Note.hx  declarations  +1 -1',
			'    ~ FnMember:run  +1 -1',
			'          \t * the file\'s name',
			'          \t */',
			'        - // old note',
			'        + // new note',
			'          foo();',
			''
		].join('\n'));
		Assert.same([], said['src/a/Note.hx']);
	}

}
