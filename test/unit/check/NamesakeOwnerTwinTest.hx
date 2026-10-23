package unit.check;

import anyparse.check.Check;
import anyparse.check.PreferEnumAbstract;
import anyparse.check.PreferInline;
import anyparse.check.UnusedPrivate;

/**
 * The supertype and subtype questions three member rules ask about the OWNER are read off the owner's DECLARATION,
 * never off every type sharing its simple name: another package's namesake, with its own supertype or subtype, changes
 * no verdict here. Each pair is the same tree with and without the namesake, so a pass cannot come from a rule going
 * silent or loud on every tree.
 */
class NamesakeOwnerTwinTest extends Test {

	/**
	 * The supertype that vetoes a member as an abstract implementation belongs to the owner's own declaration: another
	 * package's `Foo` extending a base that declares the member hides nothing on `pkg.Foo`.
	 */
	@:pin('control') @:killer('M-SUPERTYPE-DECLARES-UNION')
	public function testNamesakesSupertypeDoesNotVetoAnUnusedPrivate(): Void {
		Assert.equals(1, helperFindings(new UnusedPrivate(), 'Foo', 'Base', false), 'another package\'s Foo vetoes nothing');
		Assert.equals(1, helperFindings(new UnusedPrivate(), 'Bar', 'Base', false), 'the twin without the namesake reports');
	}

	/**
	 * The same supertype veto as `prefer-inline` asks it: a namesake's base declaring the method does not make
	 * `pkg.Foo`'s method fill a base slot.
	 */
	@:pin('control') @:killer('M-SUPERTYPE-DECLARES-UNION')
	public function testNamesakesSupertypeDoesNotVetoAnInlineCandidate(): Void {
		Assert.equals(1, helperFindings(new PreferInline(), 'Foo', 'Base', false), 'another package\'s Foo vetoes nothing');
		Assert.equals(1, helperFindings(new PreferInline(), 'Bar', 'Base', false), 'the twin without the namesake reports');
	}

	/**
	 * The subtype that makes a private member unconfined belongs to the owner's own declaration: a subtype of another
	 * package's `Foo` neither reaches this member nor shields it. That subtype names the member itself, so the
	 * project-wide fallback fails and the confinement verdict alone decides.
	 */
	@:pin('control') @:killer('M-CONFINED-NO-OWNER-FILE')
	public function testNamesakesSubtypeDoesNotUnconfineAPrivateMember(): Void {
		Assert.equals(1, helperFindings(new UnusedPrivate(), 'Foo', '', true), 'a subtype of another package\'s Foo confines nothing');
		Assert.equals(1, helperFindings(new UnusedPrivate(), 'Bar', '', true), 'the twin without the namesake reports');
	}

	/**
	 * Another package's `@:rtti` class named like `pkg.Align` does not refuse its enum-abstract conversion. `@:rtti` on the
	 * container itself is refused by the plan and its header admits no supertype, so a namesake was the only way the
	 * refusal could fire.
	 */
	@:pin('control') @:killer('M-RTTI-HOMONYM-REFUSES')
	public function testNamesakesRttiDoesNotRefuseTheConversion(): Void {
		Assert.equals(
			7, alignFixEdits([{ file: 'other/Align.hx', source: 'package other;\n\n@:rtti\nclass Align {}\n' }]),
			'another package\'s @:rtti Align refuses nothing'
		);
		Assert.equals(
			7, alignFixEdits([{ file: 'other/Plain.hx', source: 'package other;\n\nclass Plain {}\n' }]),
			'the twin without the namesake converts'
		);
	}

	/**
	 * A subtype named like its supertype in another package is a subtype like any other: its override keeps the base method
	 * physical. Only the owner's own declaration leaves the walk, and the twin without the subtype reports.
	 */
	@:pin('control') @:killer('M-SUBTYPE-MEMBERS-SKIP-NAMESAKE')
	public function testSubtypeSharingTheOwnersNameKeepsItsOverride(): Void {
		final base: { file: String, source: String } = {
			file: 'a/Client.hx',
			source: 'package a;\n\nclass Client {\n\n\tpublic function new() {}\n\n\tpublic function send():Void {}\n\n}\n'
		};
		final sub: { file: String, source: String } = {
			file: 'net/Client.hx',
			source: 'package net;\n\nclass Client extends a.Client {\n\n\toverride public function send():Void {}\n\n}\n'
		};
		inline function sends(files: Array<{ file: String, source: String }>): Int {
			return CheckFixture.violationsIn(new PreferInline(), files).filter(v -> v.file == 'a/Client.hx').length;
		}
		Assert.equals(0, sends([base, sub]), 'net.Client overrides a.Client.send');
		Assert.equals(1, sends([base]), 'the twin without the subtype reports');
	}

	/**
	 * Findings of `check` on `pkg.Foo`, whose private `helper` nothing calls, beside `other.<other>` extending
	 * `extendsName` (nothing when empty) and, with `withSub`, an `other.Sub` subtyping it that declares its own `helper`.
	 * An `other.Base` declaring a public `helper` is always present.
	 */
	private function helperFindings(check: Check, other: String, extendsName: String, withSub: Bool): Int {
		final heritage: String = extendsName == '' ? '' : ' extends $extendsName';
		final files: Array<{ file: String, source: String }> = [
			{
				file: 'pkg/Foo.hx',
				source: 'package pkg;\n\nclass Foo {\n\n\tpublic function new() {}\n\n\tprivate function helper():Int {\n\t\treturn 1;\n'
					+ '\t}\n\n}\n'
			},
			{
				file: 'other/Base.hx',
				source: 'package other;\n\nclass Base {\n\n\tpublic function new() {}\n\n\tpublic function helper():Int {\n\t\treturn 2;\n'
					+ '\t}\n\n}\n'
			},
			{ file: 'other/$other.hx', source: 'package other;\n\nclass $other$heritage {\n\n\tpublic function new() {}\n\n}\n' }
		];
		if (withSub) files.push({
			file: 'other/Sub.hx',
			source: 'package other;\n\nclass Sub extends $other {\n\n\tpublic function helper():Int {\n\t\treturn 3;\n\t}\n\n}\n'
		});
		return CheckFixture.violationsIn(check, files).filter(v -> v.file == 'pkg/Foo.hx').length;
	}

	/**
	 * The edits `prefer-enum-abstract`'s grouped fix makes to a three-constant `pkg.Align`, beside `others`.
	 */
	private function alignFixEdits(others: Array<{ file: String, source: String }>): Int {
		final decl: String = 'package pkg;\n\nclass Align { public static inline final A:String = \'a\'; public static inline final '
			+ 'B:String = \'b\'; public static inline final C:String = \'c\'; }';
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final files: Array<{ file: String, source: String }> = [{ file: 'pkg/Align.hx', source: decl }].concat(others);
		final check: PreferEnumAbstract = new PreferEnumAbstract();
		final vs: Array<Violation> = CheckFixture.violationsIn(check, files, plugin).filter(v -> v.file == 'pkg/Align.hx');
		return check.fixGrouped(decl, vs, plugin, CheckFixture.index(files, plugin)).length;
	}

}
