// lib/services/carrot_wallet.dart
//
// Carrots are Hops' in-app currency, earned by playing Hops Hopper/Hops
// Wordle and spent in the Hops Shop on premium customization (see
// hops_shop_page.dart). This class is a deliberate PLACEHOLDER: a balance
// that lives only in SharedPreferences, with nothing behind it but the
// honor system.
//
// That's an accepted tradeoff, not an oversight: the Hops website's credit
// shop (buy carrots with real money) was scoped to stay decoupled from the
// app on purpose — no purchase-verification backend, so nothing server-side
// ever needs to be trusted here. The only way to get carrots is by playing
// the games, which makes the worst case of a modified client editing its
// own local balance "free cosmetic customization," not a financial fraud
// problem. If a real-money path into the app ever gets built after all,
// THAT is the point this needs to become a server-authoritative ledger —
// not a moment before, since there's nothing worth protecting until then.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CarrotWallet {
  CarrotWallet._();
  static final CarrotWallet instance = CarrotWallet._();

  static const _prefsKey = 'carrot_balance_local_v1';
  static const _ownedKey = 'carrot_owned_items_v1';

  /// TESTING/DEMO ONLY — makes purchase() succeed regardless of balance, so
  /// QA or a hackathon demo can unlock every Shop item without grinding the
  /// games first. UI spots that show the numeric balance (hopper/wordle app
  /// bars, the Shop page) should show '∞' instead when this is true, so
  /// it's obvious the number isn't real. Flip to false before a real
  /// launch — this deliberately breaks the "earn it or don't own it"
  /// economy described in the header comment above.
  static const bool debugUnlimitedCarrots = true;

  /// Current balance. 0 until load() resolves — callers that need a real
  /// number before first paint should await load() themselves rather than
  /// trust the initial value.
  final ValueNotifier<int> balance = ValueNotifier<int>(0);

  /// Shop items this device has unlocked, by id (a premium AppTheme's
  /// `name`, for now — see hops_shop_page.dart). A Set so owns() and the
  /// Shop grid's "already bought" state are both cheap membership checks.
  final ValueNotifier<Set<String>> owned = ValueNotifier<Set<String>>(<String>{});

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    balance.value = prefs.getInt(_prefsKey) ?? 0;
    owned.value = (prefs.getStringList(_ownedKey) ?? const []).toSet();
  }

  bool owns(String itemId) => owned.value.contains(itemId);

  /// Credits [amount] carrots (e.g. a game's completion reward). No-op for
  /// zero/negative amounts.
  Future<void> earn(int amount) async {
    if (amount <= 0) return;
    await load();
    final prefs = await SharedPreferences.getInstance();
    balance.value += amount;
    await prefs.setInt(_prefsKey, balance.value);
  }

  /// Attempts to buy [itemId] for [cost] carrots. Returns false without
  /// changing anything if the balance is short or it's already owned —
  /// callers (the Shop's Buy button) are expected to have already disabled
  /// themselves in either case, so this is a safety net, not the primary
  /// gate.
  Future<bool> purchase(String itemId, int cost) async {
    await load();
    if (owned.value.contains(itemId)) return false;
    if (!debugUnlimitedCarrots && balance.value < cost) return false;

    if (!debugUnlimitedCarrots) balance.value -= cost;
    owned.value = {...owned.value, itemId};

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKey, balance.value);
    await prefs.setStringList(_ownedKey, owned.value.toList());
    return true;
  }
}
