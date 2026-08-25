# Polskie dyktowanie lokalne w Windows

Powtarzalna, prywatna instalacja aplikacji Handy do lokalnego dyktowania po polsku.

Po instalacji:

- `Ctrl` + `*` na klawiaturze numerycznej rozpoczyna nagrywanie;
- ten sam skrót kończy nagrywanie, wykonuje transkrypcję i wkleja tekst;
- `Escape` anuluje nagranie;
- tekst pozostaje również w schowku;
- Handy uruchamia się w zasobniku razem z Windowsem;
- mikrofon nie jest stale aktywny, nagrania nie są zachowywane, a post-processing sieciowy jest wyłączony.

## Instalacja na drugim komputerze

Wymagany jest Windows 10/11 x64 i połączenie z internetem podczas instalacji. Uprawnienia administratora nie powinny być potrzebne.

Najprościej:

1. Otwórz to prywatne repozytorium na GitHubie.
2. Wybierz **Code → Download ZIP** i rozpakuj archiwum.
3. Kliknij dwukrotnie `Uruchom instalacje.cmd`.
4. Po komunikacie „Gotowe” ustaw kursor w dowolnym polu tekstowym i wypróbuj `Ctrl` + numpad `*`.

Jeżeli masz Git:

```powershell
git clone https://github.com/HjustonAI/handy-polish-dictation.git
cd handy-polish-dictation
.\Uruchom instalacje.cmd
```

Instalator sam:

1. pobiera przypiętą i podpisaną wersję Handy;
2. sprawdza podpis Authenticode oraz SHA-256;
3. analizuje urządzenia obliczeniowe udostępnione przez Handy;
4. wybiera Whisper Large v3 Turbo Q8 na odpowiednim dedykowanym GPU albo szybszy Parakeet V3 na słabszym komputerze;
5. pobiera model z oficjalnego źródła i weryfikuje jego SHA-256;
6. wykrywa wejście Focusrite, a jeśli go nie ma — pozostawia domyślne wejście Windows;
7. nakłada bezpieczny zestaw ustawień i włącza autostart;
8. kontroluje wynik bez włączania ani testowania mikrofonu.

## Przydatne warianty

Wymuszenie Whispera niezależnie od sprzętu:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-HandyDictation.ps1 -Engine Whisper
```

Wymuszenie szybszego Parakeeta:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-HandyDictation.ps1 -Engine Parakeet
```

Wybór urządzenia o dokładnej nazwie:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-HandyDictation.ps1 -MicrophoneName 'Analogue 1 + 2 (Focusrite USB Audio)'
```

Sama kontrola istniejącej instalacji:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-HandyDictation.ps1 -AuditOnly
```

To samo można zrobić dwuklikiem przez `Sprawdz instalacje.cmd`.

## Dobór modelu

Tryb `Auto` wybiera Whispera, gdy Handy widzi obsługiwane dedykowane GPU NVIDIA, AMD Radeon RX/Pro albo Intel Arc z co najmniej 3,5 GB raportowanej pamięci. W pozostałych przypadkach wybiera Parakeeta.

- **Whisper Large v3 Turbo Q8** — preferowany dla jakości polszczyzny; pobieranie około 845 MB.
- **Parakeet V3 int8** — znacznie szybszy na CPU, z niewielką stratą dokładności; pobieranie około 456 MB.

Na komputerze, dla którego powstało to repo, Whisper na RTX 2080 Super Max-Q przepisywał próbkę około 2,6 raza szybciej od czasu rzeczywistego. Parakeet na CPU był około 8,5 raza szybszy, ale popełnił o jeden błąd więcej w polskiej próbce.

## Prywatność i bezpieczeństwo

Repozytorium zawiera wyłącznie skrypty, jawne ustawienia i manifest wersji. Nie zawiera:

- modelu ani instalatora — są za duże i pochodzą z zewnętrznych projektów;
- nagrań lub historii transkrypcji;
- rzeczywistego `settings_store.json`, który mógłby kiedyś zawierać prywatne ustawienia lub klucze API.

Wersje, adresy i oczekiwane sumy SHA-256 są przypięte w [`config/versions.json`](config/versions.json). Instalator Handy musi dodatkowo mieć prawidłowy podpis cyfrowy wydawcy YNYNG LLC.

Instalator nie nagrywa testowej próbki. Pierwszy dostęp do mikrofonu nastąpi dopiero po świadomym naciśnięciu skrótu. Cała transkrypcja działa lokalnie; post-processing i klucze usług chmurowych nie są konfigurowane.

## Ponowne uruchomienie i kopie ustawień

Skrypt jest idempotentny — można uruchomić go ponownie. Przed zmianą konfiguracji zapisuje kopię poprzednich ustawień w:

```text
%APPDATA%\com.pais.handy\settings_store.RRRRMMDD-GGMMSS.backup.json
```

Nie usuwa historii ani innych danych użytkownika Handy. Jeśli trafi na niekompletny katalog modelu Parakeet, przenosi go obok z dopiskiem `.broken-DATA`, zamiast kasować.

## Co aktualizować

Nie zmieniaj samych adresów pobierania bez aktualizacji sum SHA-256. Przy świadomej zmianie wersji:

1. sprawdź oficjalne wydanie Handy i jego podpis cyfrowy;
2. zaktualizuj `config/versions.json`;
3. wykonaj instalację oraz `Sprawdz instalacje.cmd` na czystym profilu Windows;
4. sprawdź ręcznie skrót, mikrofon, polski tekst i wklejanie.

Przypięcie wersji jest celowe: zapewnia ten sam, sprawdzony rezultat na kolejnych komputerach.
