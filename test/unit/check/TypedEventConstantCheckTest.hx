package unit.check;

import anyparse.check.Check.Violation;
import anyparse.check.LintConfig;
import anyparse.check.RuleDeclaration;
import anyparse.check.Severity;
import anyparse.check.TypedEventConstant;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;
import utest.Assert;
import utest.Test;

using StringTools;

/**
 * The `typed-event-constant` check: a `String` constant of an event class, used as a listener's or an event's type, is
 * reported and retyped to the declared event-type abstract over the class (`EventType<PopupEvent>`); a listener or a
 * dispatch the retype would reject is reported as the latent bug it is, at the use, and its constant is left alone.
 * The candidate gates — an event class, a static final string, a use as an event type — and the reader's and the
 * index's verdicts on the declaration are each pinned by their own fixture.
 */
class TypedEventConstantCheckTest extends Test {

	private static final EVENT: String =
		'package ev;\n\nclass Event {\n\tpublic var type:String;\n\n\tpublic function new(type:String) {\n\t\tthis.type = type;\n\t}\n}\n';
	private static final EVENT_TYPE: String = 'package ev;\n\nabstract EventType<T>(String) from String to String {}\n';

	/** Converts from String only: `to String` is what keeps a retyped constant usable as a String. */
	private static final ONE_WAY_TYPE: String = 'package ev;\n\nabstract OneWay<T>(String) from String {}\n';

	private static final DISPATCHER: String = 'package ev;\n\nclass Dispatcher {\n\tpublic function new() {}\n\n'
		+ '\tpublic function addEventListener<T>(type:EventType<T>, listener:T -> Void):Void {}\n\n'
		+ '\tpublic function dispatchEvent(e:Event):Void {}\n}\n';
	private static final POPUP_EVENT: String = 'package app;\n\nimport ev.Event;\n\nclass PopupEvent extends Event {\n'
		+ '\tpublic static inline final CLOSE:String = \'close\';\n\tpublic static inline final OPEN:String = \'open\';\n'
		+ '\tpublic static final UNUSED:String = \'unused\';\n\tpublic static var MUT:String = \'mut\';\n}\n';
	private static final MOUSE_EVENT: String = 'package app;\n\nimport ev.Event;\n\nclass MouseEv extends Event {}\n';
	private static final SUB_POPUP: String = 'package app;\n\nclass SubPopup extends PopupEvent {}\n';
	private static final NOT_EVENT: String =
		'package app;\n\nclass NotEvent {\n\tpublic static inline final CLOSE:String = \'close\';\n}\n';
	private static final CONFIG: String =
		'{"rules":{"typed-event-constant":{"eventBase":"ev.Event","typeAbstract":"ev.EventType","listenerMethods":["addEventListener"]}}}';

	public function testAConstantUsedAsAnEventTypeIsReportedAndRetyped(): Void {
		final files: Array<{ file: String, source: String }> = project('d.addEventListener(PopupEvent.CLOSE, onEvent);');
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals('typed-event-constant', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('app/PopupEvent.hx', vs[0].file);
		Assert.isTrue(vs[0].message.indexOf('PopupEvent.CLOSE') != -1, vs[0].message);
		Assert.same(['ev.EventType<PopupEvent>'], editTexts(files, 'app/PopupEvent.hx'));
	}

	public function testTheAbstractIsSpelledShortWhereItIsAlreadyImported(): Void {
		final files: Array<{ file: String, source: String }> = project('d.addEventListener(PopupEvent.CLOSE, onEvent);');
		files[0] = {
			file: 'app/PopupEvent.hx',
			source: POPUP_EVENT.replace('import ev.Event;\n', 'import ev.Event;\nimport ev.EventType;\n')
		};
		Assert.same(['EventType<PopupEvent>'], editTexts(files, 'app/PopupEvent.hx'));
	}

	public function testADispatchedEventOfTheClassCountsAsAUse(): Void {
		final vs: Array<Violation> = violationsOf(project('d.dispatchEvent(new SubPopup(PopupEvent.CLOSE));'));
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals(Severity.Info, vs[0].severity);
	}

	/** The listener is handed a `PopupEvent` it declares to be a `MouseEv`: reported at the use, the constant left alone. */
	@:pin('control') @:killer('M-EVENT-NO-MISMATCH')
	public function testALambdaListenerOfAnotherEventClassIsALatentBug(): Void {
		final files: Array<{ file: String, source: String }> = project('d.addEventListener(PopupEvent.OPEN, (e:MouseEv) -> {});');
		final vs: Array<Violation> = violationsOf(files);
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.equals('app/Main.hx', vs[0].file);
		Assert.equals('listener (e:MouseEv) -> {} of PopupEvent.OPEN expects MouseEv, the event is PopupEvent', vs[0].message);
		Assert.equals('typing PopupEvent.OPEN EventType<PopupEvent> would not compile here', vs[0].declineReason);
		Assert.same([], editTexts(files, 'app/PopupEvent.hx'));
	}

	@:pin('control') @:killer('M-EVENT-NO-MISMATCH')
	public function testAMethodListenerOfASubclassIsALatentBug(): Void {
		final vs: Array<Violation> = violationsOf(project('d.addEventListener(PopupEvent.OPEN, this.onSub);'));
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals('listener this.onSub of PopupEvent.OPEN expects SubPopup, the event is PopupEvent', vs[0].message);
	}

	@:pin('control') @:killer('M-EVENT-NO-MISMATCH')
	public function testAFunctionTypedLocalListenerIsALatentBug(): Void {
		final vs: Array<Violation> =
			violationsOf(project('final held:MouseEv->Void = e -> {};\n\t\td.addEventListener(PopupEvent.OPEN, held);'));
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals('listener held of PopupEvent.OPEN expects MouseEv, the event is PopupEvent', vs[0].message);
	}

	@:pin('control') @:killer('M-EVENT-NO-MISMATCH')
	public function testAnEventDispatchedAsAnotherClassIsALatentBug(): Void {
		final vs: Array<Violation> = violationsOf(project('d.dispatchEvent(new Event(PopupEvent.CLOSE));'));
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals(Severity.Warning, vs[0].severity);
		Assert.isTrue(vs[0].message.startsWith('PopupEvent.CLOSE is dispatched as new Event(…), the event is PopupEvent'), vs[0].message);
	}

	public function testASupertypeListenerIsConsistent(): Void {
		final vs: Array<Violation> = violationsOf(project('d.addEventListener(PopupEvent.OPEN, (e:Event) -> {});'));
		Assert.equals(1, vs.length, messages(vs));
		Assert.equals(Severity.Info, vs[0].severity);
	}

	@:pin('control') @:killer('M-EVENT-NO-USE-GATE')
	public function testAConstantNeverUsedAsAnEventTypeIsNotReported(): Void {
		Assert.equals(0, violationsOf(project('trace(PopupEvent.UNUSED);')).length);
	}

	/** A string handed to the constructor of a class that is no event is not an event type, and no dispatch to judge. */
	@:pin('control') @:killer('M-EVENT-ANY-NEW-IS-A-USE')
	public function testAConstructorOfANonEventClassIsNoUse(): Void {
		Assert.equals(0, violationsOf(project('trace(new NotEvent(PopupEvent.UNUSED));')).length);
	}

	@:pin('control') @:killer('M-EVENT-STATIC-VAR')
	public function testAStaticVarIsNoConstant(): Void {
		Assert.equals(0, violationsOf(project('d.addEventListener(PopupEvent.MUT, onEvent);')).length);
	}

	@:pin('control') @:killer('M-EVENT-NO-BASE-GATE')
	public function testAConstantOfAClassThatIsNoEventIsNotReported(): Void {
		Assert.equals(0, violationsOf(project('d.addEventListener(NotEvent.CLOSE, onEvent);')).length);
	}

	public function testNoConfigIsInert(): Void {
		Assert.equals(0, violationsOf(project('d.addEventListener(PopupEvent.CLOSE, onEvent);'), '{}').length);
		Assert.equals('needs-config', new TypedEventConstant().skipReason('app/Main.hx', LintConfig.parse('{}')));
		Assert.isNull(new TypedEventConstant().skipReason('app/Main.hx', LintConfig.parse(CONFIG)));
	}

	/** Without `to String` every comparison or String use of a retyped constant stops compiling. */
	@:pin('control') @:killer('M-EVENT-ABSTRACT-TRUSTED')
	public function testAnAbstractWithoutBothStringConversionsMakesTheRuleInert(): Void {
		final config: String = CONFIG.replace('ev.EventType', 'ev.OneWay');
		final files: Array<{ file: String, source: String }> = project('d.addEventListener(PopupEvent.CLOSE, onEvent);');
		Assert.equals(0, violationsOf(files, config).length);
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final problems: Array<String> = [];
		final spec: Null<EventSpec> = RuleDeclaration.eventTypes(LintConfig.parse(config), 'typed-event-constant', []);
		Assert.notNull(spec);
		if (spec != null) Assert.isNull(TypedEventConstant.validate(spec, SymbolIndex.build(files, plugin), plugin, problems));
		Assert.same([
			'"typeAbstract" "ev.OneWay" is not an abstract of one type parameter over String converting from String and to String — rule '
			+ 'inert'
		], problems);
	}

	public function testTheReaderNamesAWrongTypedKey(): Void {
		final problems: Array<String> = [];
		Assert.isNull(RuleDeclaration.eventTypes(
			LintConfig.parse(
				'{"rules":{"typed-event-constant":{"eventBase":1,"typeAbstract":"ev.EventType","listenerMethods":"addEventListener"}}}'
			),
			'typed-event-constant', problems
		));
		Assert.same([
			'"eventBase" is not a type path — ignored',
			'"listenerMethods" is not an array — ignored'
		], problems);
		final unknownBase: Array<String> = [];
		final files: Array<{ file: String, source: String }> = project('');
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final spec: Null<EventSpec> = RuleDeclaration.eventTypes(
			LintConfig.parse(CONFIG.replace('ev.Event"', 'ev.Nope"')), 'typed-event-constant', []
		);
		if (spec != null) Assert.isNull(TypedEventConstant.validate(spec, SymbolIndex.build(files, plugin), plugin, unknownBase));
		Assert.same([
			'"eventBase" "ev.Nope" names no single type in the resolution scope — rule inert'
		], unknownBase);
	}

	/** The fixture project: the event declarations first, then the user file whose `run` body is `body`. */
	private function project(body: String): Array<{ file: String, source: String }> {
		final main: String = 'package app;\n\nimport ev.Dispatcher;\nimport ev.Event;\n\nclass Main {\n\tpublic function new() {}\n\n'
			+ '\tfunction run(d:Dispatcher):Void {\n\t\t$body\n\t}\n\n\tfunction onEvent(e:Event):Void {}\n\n'
			+ '\tfunction onSub(e:SubPopup):Void {}\n}\n';
		return [
			{ file: 'app/PopupEvent.hx', source: POPUP_EVENT },
			{ file: 'app/Main.hx', source: main },
			{ file: 'app/MouseEv.hx', source: MOUSE_EVENT },
			{ file: 'app/SubPopup.hx', source: SUB_POPUP },
			{ file: 'app/NotEvent.hx', source: NOT_EVENT },
			{ file: 'ev/Event.hx', source: EVENT },
			{ file: 'ev/EventType.hx', source: EVENT_TYPE },
			{ file: 'ev/OneWay.hx', source: ONE_WAY_TYPE },
			{ file: 'ev/Dispatcher.hx', source: DISPATCHER }
		];
	}

	private function check(config: String): TypedEventConstant {
		final rule: TypedEventConstant = new TypedEventConstant();
		rule.setConfigResolver(_ -> LintConfig.parse(config));
		return rule;
	}

	private function violationsOf(files: Array<{ file: String, source: String }>, ?config: String): Array<Violation> {
		return check(config ?? CONFIG).run(files, new HaxeQueryPlugin());
	}

	/** The replacement texts of the fix for `file`'s own findings. */
	private function editTexts(files: Array<{ file: String, source: String }>, file: String): Array<String> {
		final plugin: HaxeQueryPlugin = new HaxeQueryPlugin();
		final rule: TypedEventConstant = check(CONFIG);
		final own: Array<Violation> = rule.run(files, plugin).filter(v -> v.file == file);
		if (own.length == 0) return [];
		final source: String = files.filter(f -> f.file == file)[0].source;
		final edits: Array<{ span: Span, text: String }> = rule.fix(source, own, plugin, SymbolIndex.build(files, plugin));
		return [for (e in edits) e.text];
	}

	private static function messages(vs: Array<Violation>): String {
		return [for (v in vs) '${v.file} ${v.severity} ${v.message}'].join('\n');
	}

}
