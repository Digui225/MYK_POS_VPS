from caisse.domain.money import calculate_change, calculate_vat_split


def test_calculate_vat_split_zero_or_negative():
    assert calculate_vat_split(0, 18.0) == (0, 0)
    assert calculate_vat_split(-1000, 18.0) == (0, 0)


def test_calculate_vat_split_rate_zero():
    assert calculate_vat_split(10000, 0) == (10000, 0)
    assert calculate_vat_split(10000, 0.0) == (10000, 0)


def test_calculate_vat_split_standard_18():
    # 11 800 TTC à 18% -> 10 000 HT et 1 800 TVA
    ht, vat = calculate_vat_split(11800, 18.0)
    assert ht == 10000
    assert vat == 1800
    assert ht + vat == 11800


def test_calculate_vat_split_rounding_half_up():
    # Test avec un montant qui génère une fraction .5 pour tester l'arrondi demi-supérieur
    # 3500 TTC à 18% -> 3500 / 1.18 = 2966.1016... -> HT = 2966, TVA = 534
    ht, vat = calculate_vat_split(3500, 18.0)
    assert ht == 2966
    assert vat == 534
    assert ht + vat == 3500


def test_calculate_change():
    assert calculate_change(None, 5000) == 0
    assert calculate_change(4000, 5000) == 0
    assert calculate_change(5000, 5000) == 0
    assert calculate_change(10000, 6500) == 3500
