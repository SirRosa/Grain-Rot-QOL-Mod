# Grain Rot QOL — osobny mod UE4SS

## v0.1.2 stutter hotfix — test

- UE4SS timer 750 ms is the source of scheduling truth: avoids Windows `os.clock()` (process CPU time) accelerating the 2/4/10-second sweeps.
- Instead of querying every `HeldenEquipableItem` for each durability repair, checks the players' equipped/slotted items. Extra owned items are refreshed periodically rather than on every inventory snapshot.
- Logs `PERF slow poll CPU=...ms` for unusually expensive polling cycles (diagnostic approximation, not engine frame time).
- Same XP, wallet multipliers and durability feature switches as before. `InsuranceOnWipe` should be false when Expedition Saver handles equipment restoration.
- Test version: GitHub Actions mock checks only; measure actual FPS and stutter in the game before merging to main.


**v0.1.0-preview — wersja testowa.** Nie zastępuje Grain Rot Depth Keeper, można instalować równolegle. Instalacja tylko na komputerze hosta.

## Funkcje

1. **Odzyskiwanie wyposażenia po śmierci (eksperymentalne).** W czasie wyprawy mod zapamiętuje przedmioty w ekwipunku postaci. Po potwierdzonym nieudanym zakończeniu wyprawy host próbuje odtworzyć brakujące przedmioty w windzie. Odtworzenie aktorów i trwałość zapisu **nie zostały jeszcze sprawdzone w działającej grze**. Nie gwarantuje zachowania zaklęć ani wszystkich slotów. Nie wykonuje automatycznych ponownych prób po częściowym odtworzeniu, aby unikać duplikowania.
2. **Trwałość.** Przywraca maksymalną trwałość niepalnego wyposażenia i ustawia brak utraty trwałości w tabeli HeldenItemData dla pozycji jednoznacznie rozpoznanych jako nienależące do grupy broni dystansowej. Broniom klasy HeldenRangedWeapon pozostawia zużycie w lochu; w bazie odnawia je do maksimum. Ta klasa obejmuje także niektóre inne bronie dystansowe.
3. **Meble XP ×5.** Modyfikuje pole XP w wierszach HeldenConstructAssetData i HeldenPhysActorData (np. small plant: 6 → 30).
4. **Złoto ×3, graty ×15.** Modyfikuje pola Parsed_ScrapValue_Common/Rare/Epic.Gold i Parsed_ScrapReward.Gold. Bazowe wartości 1 → 15, pozostałe dodatnie ×3 (np. 20 → 60). Nie dotyczy ceny zakupu ani bezpośrednio generowanych monet.

## Instalacja

1. Zrób **kopię zapisu gry**. Zainstalowany wcześniej UE4SS zostaw bez zmian.
2. Pobierz ZIP z ostatniego udanego GitHub Actions, rozpakuj do katalogu Grain Rot/Helden/Binaries/Win64/.
3. Sprawdź, czy powstały ue4ss/Mods/GrainRotQOL/Scripts/main.lua oraz enabled.txt.
4. W co-op zainstaluj wyłącznie na **hoście**.

## Weryfikacja

W UE4SS.log sprawdź wpisy z prefiksem [GrainRotQOL]. Wpisy ConstructAssetData ready, PhysActorData ready oraz ItemData ready potwierdzają, że API danych jest dostępne. WAIT oznacza nieudany dostęp do tabeli w tym buildzie UE4SS. Wpis failed expedition: queued oznacza liczbę zapamiętanych przedmiotów; insurance delivery oznacza próbę ich odtworzenia.

Najpierw testuj XP mebli i złoto, potem trwałość. Przenoszenie przedmiotów sprawdzaj na osobnym zapisie z jednym niecennym przedmiotem — bez gwarancji, że nowo utworzony aktor będzie miał identyczny typ, modyfikacje lub poprawnie zapisze się po restarcie.

## Ograniczenia

To wersja implementacyjna oparta na polach dostarczonego mapowania Helden UE 5.7.4. Nie uruchamiano jej wewnątrz Grain Rot. GitHub Actions uruchamia testy z symulatorem UE4SS, które nie wykrywają różnic w realnym cyklu zapisywania gry. Właściwe metody zapisu ekwipunku przez serwer wymagają dodatkowej weryfikacji w logu. Dane tabel modyfikowane są jednokrotnie, a skrypt ogranicza koszt cyklicznych odczytów.

Źródła: dostarczone mapowanie Helden.usmap oraz dokumentacja UE4SS.