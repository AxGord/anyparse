package unit.ds;

/** A parameterless enum: a constructor's bit is its index. */
enum Hue {
	Red;
	Green;
	Blue;
}

/** Thirty-two values, 0 to 31: the widest domain one `Int` holds. */
enum abstract Narrow(Int) {
	final Low = 0;
	final Next = 1;
	final N2 = 2;
	final N3 = 3;
	final N4 = 4;
	final N5 = 5;
	final N6 = 6;
	final N7 = 7;
	final N8 = 8;
	final N9 = 9;
	final N10 = 10;
	final N11 = 11;
	final N12 = 12;
	final N13 = 13;
	final N14 = 14;
	final N15 = 15;
	final N16 = 16;
	final N17 = 17;
	final N18 = 18;
	final N19 = 19;
	final N20 = 20;
	final N21 = 21;
	final N22 = 22;
	final N23 = 23;
	final N24 = 24;
	final N25 = 25;
	final N26 = 26;
	final N27 = 27;
	final N28 = 28;
	final N29 = 29;
	final N30 = 30;
	final Top = 31;
}

/** Sixty-four values, 0 to 63: both edges of both words of a two-word store. */
enum abstract Wide(Int) {
	final Low = 0;
	final W1 = 1;
	final W2 = 2;
	final W3 = 3;
	final W4 = 4;
	final W5 = 5;
	final W6 = 6;
	final W7 = 7;
	final W8 = 8;
	final W9 = 9;
	final W10 = 10;
	final W11 = 11;
	final W12 = 12;
	final W13 = 13;
	final W14 = 14;
	final W15 = 15;
	final W16 = 16;
	final W17 = 17;
	final W18 = 18;
	final W19 = 19;
	final W20 = 20;
	final W21 = 21;
	final W22 = 22;
	final W23 = 23;
	final W24 = 24;
	final W25 = 25;
	final W26 = 26;
	final W27 = 27;
	final W28 = 28;
	final W29 = 29;
	final W30 = 30;
	final Last = 31;
	final First = 32;
	final W33 = 33;
	final W34 = 34;
	final W35 = 35;
	final W36 = 36;
	final W37 = 37;
	final W38 = 38;
	final W39 = 39;
	final W40 = 40;
	final W41 = 41;
	final W42 = 42;
	final W43 = 43;
	final W44 = 44;
	final W45 = 45;
	final W46 = 46;
	final W47 = 47;
	final W48 = 48;
	final W49 = 49;
	final W50 = 50;
	final W51 = 51;
	final W52 = 52;
	final W53 = 53;
	final W54 = 54;
	final W55 = 55;
	final W56 = 56;
	final W57 = 57;
	final W58 = 58;
	final W59 = 59;
	final W60 = 60;
	final W61 = 61;
	final W62 = 62;
	final Top = 63;
}

/** Values far apart: each takes the bit of its rank, so the store is one `Int`. */
enum abstract Sparse(Int) {
	final Zero = 0;
	final Far = 200000000;
}

/** Flag-style values written as literals, the top one at bit 30 of its own `Int`. */
enum abstract Flag(Int) {
	final One = 1;
	final Two = 2;
	final Four = 4;
	final Huge = 1073741824;
}
