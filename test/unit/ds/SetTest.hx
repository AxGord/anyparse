package unit.ds;

import anyparse.ds.Set;

/** `anyparse.ds.Set`: the membership contract every target keeps, for the three key kinds the project uses. */
class SetTest extends Test {

	public function testStringKeys(): Void {
		final set: Set<String> = new Set<String>();
		Assert.isFalse(set.has('a'));
		set.add('a');
		set.add('a');
		Assert.isTrue(set.has('a'));
		Assert.isFalse(set.has('b'));
		Assert.isTrue(set.remove('a'));
		Assert.isFalse(set.remove('a'));
		Assert.isFalse(set.has('a'));
	}

	public function testIntKeys(): Void {
		final set: Set<Int> = new Set<Int>();
		set.add(3);
		Assert.isTrue(set.has(3));
		Assert.isFalse(set.has(4));
		Assert.isTrue(set.remove(3));
	}

	/** An object is a member by identity, never by shape. */
	public function testObjectKeysByIdentity(): Void {
		final first: Holder = new Holder();
		final set: Set<Holder> = new Set<Holder>();
		set.add(first);
		Assert.isTrue(set.has(first));
		Assert.isFalse(set.has(new Holder()));
	}

	public function testIterationVisitsEveryKeyOnce(): Void {
		final set: Set<String> = new Set<String>();
		for (key in ['x', 'y', 'z', 'x']) set.add(key);
		final seen: Array<String> = [for (key in set) key];
		seen.sort(Reflect.compare);
		Assert.same(['x', 'y', 'z'], seen);
		Assert.isFalse(new Set<String>().iterator().hasNext());
	}

	public function testClearEmptiesTheSet(): Void {
		final set: Set<String> = new Set<String>();
		set.add('a');
		set.clear();
		Assert.isFalse(set.has('a'));
		set.add('b');
		Assert.isTrue(set.has('b'));
	}

	/** A copy no longer shares storage with its source. */
	public function testCopyIsIndependent(): Void {
		final set: Set<Int> = new Set<Int>();
		set.add(1);
		final copy: Set<Int> = set.copy();
		set.add(2);
		copy.add(3);
		Assert.isTrue(copy.has(1));
		Assert.isFalse(copy.has(2));
		Assert.isFalse(set.has(3));
	}

}

private final class Holder {

	public function new() {}

}
