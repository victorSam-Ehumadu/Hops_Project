import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AutofillHints, TextInput;
import 'package:client/widgets/hops_background_pattern.dart';
import 'package:client/widgets/hops_flip_card.dart';
import 'package:client/widgets/password_strength_bar.dart';
import 'package:client/utils/password_policy.dart';
import 'package:client/views/forgot_password_screen.dart';

class AuthScreen extends StatefulWidget {
  final Future<void> Function({
  required String email,
  required String password,
  required String username,
  }) onSignUpTrigger;

  final Future<void> Function({
  required String email,
  required String password,
  }) onSignInTrigger;

  final String currentStatus;

  const AuthScreen({
    super.key,
    required this.onSignUpTrigger,
    required this.onSignInTrigger,
    required this.currentStatus,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentStep = 0;
  bool isJoinMeshMode = true;

  // Separate controllers per form — these used to be shared between Join
  // Hops and Sign In (both used _emailController/_passwordController),
  // which is why typing in one form's fields made the same text appear in
  // the other's: they were, quite literally, the same TextEditingController.
  final _usernameController = TextEditingController();
  final _signupEmailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _signinEmailController = TextEditingController();
  final _signinPasswordController = TextEditingController();

  // One FocusNode per field — drives two things while focused: the small
  // requirement line that separates from the label ("Must be at least ...")
  // and whether the bunny-themed hint text is visible at all (unfocused
  // fields look completely empty, same as the password field always has).
  final _usernameFocus = FocusNode();
  final _signupEmailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmPasswordFocus = FocusNode();
  final _signinEmailFocus = FocusNode();
  final _signinPasswordFocus = FocusNode();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;
  String? _fieldError; // inline, non-technical validation message

  // Plays once on first launch of this screen — an explicit controller
  // rather than e.g. TweenAnimationBuilder specifically so it doesn't
  // re-trigger every time the password fields' listeners below call
  // setState() (which rebuilds this whole screen, including the
  // onboarding page sitting inert underneath the form page in the
  // PageView) — that would've made the logo visibly bounce on every
  // keystroke.
  late final AnimationController _logoController;
  late final Animation<double> _logoScale;

  @override
  void initState() {
    super.initState();
    for (final c in [
      _usernameController,
      _signupEmailController,
      _passwordController,
      _confirmPasswordController,
      _signinEmailController,
      _signinPasswordController,
    ]) {
      c.addListener(() => setState(() {}));
    }
    for (final f in [
      _usernameFocus,
      _signupEmailFocus,
      _passwordFocus,
      _confirmPasswordFocus,
      _signinEmailFocus,
      _signinPasswordFocus,
    ]) {
      f.addListener(() => setState(() {}));
    }
    _logoController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _logoScale = CurvedAnimation(parent: _logoController, curve: Curves.elasticOut);
    _logoController.forward();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _usernameController.dispose();
    _signupEmailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _signinEmailController.dispose();
    _signinPasswordController.dispose();
    _usernameFocus.dispose();
    _signupEmailFocus.dispose();
    _passwordFocus.dispose();
    _confirmPasswordFocus.dispose();
    _signinEmailFocus.dispose();
    _signinPasswordFocus.dispose();
    _logoController.dispose();
    // Tells the platform (Google Password Manager / iOS Keychain / etc.)
    // this screen's autofill-eligible forms are done being interacted
    // with, which is what actually triggers the "Save password?" prompt.
    // AuthScreen only ever gets torn down by a successful sign-in/sign-up
    // navigating away from it — on a failed attempt nothing navigates and
    // this widget just stays mounted — so dispose() firing is a reliable
    // enough "the credentials just typed in were good" signal, without
    // needing to plumb an explicit success/failure result back from
    // root_gatekeeper.dart's callbacks (which currently only communicate
    // via the currentStatus string, not a return value).
    TextInput.finishAutofillContext();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          // Theme-reactive rather than the two hardcoded teal hex codes
          // this used to be — theme/font choices are saved to
          // SharedPreferences and survive sign-out, so a returning user
          // on a dark theme would otherwise land back on a jarring fixed
          // light gradient before they've even logged in.
          gradient: RadialGradient(
            center: const Alignment(-0.6, -0.4),
            radius: 1.2,
            colors: [colors.surface, theme.scaffoldBackgroundColor],
          ),
        ),
        child: HopsBackgroundPattern(child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                child: Row(
                  children: [
                    Icon(Icons.cruelty_free, color: colors.primary),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text("Hops",
                          style: theme.textTheme.headlineMedium,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(2, (index) => AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _currentStep == index ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentStep == index ? colors.primary : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(100),
                  ),
                )),
              ),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) => setState(() => _currentStep = page),
                  children: [
                    _buildOnboardingInfoStep(),
                    _buildInteractiveFormStep(),
                  ],
                ),
              ),
            ],
          ),
        )),
      ),
    );
  }

  Widget _buildOnboardingInfoStep() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),
          // The app's actual brand identity, front and center at the
          // exact moment someone forms their first impression — not just
          // a small 24px icon next to the wordmark up top.
          ScaleTransition(
            scale: _logoScale,
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.primary,
                boxShadow: [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: 0.35),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.cruelty_free, color: Colors.white, size: 56),
            ),
          ),
          const SizedBox(height: 20),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text("Welcome to Hops",
                style: theme.textTheme.displayLarge?.copyWith(fontSize: 32)),
          ),
          const SizedBox(height: 8),
          Text(
            "The offline campus network that lets you chat, share, and stay safe — no Wi‑Fi or data needed.",
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurface.withValues(alpha: 0.6), fontSize: 14),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 40),
          _buildBentoInfoCard(
            title: "No Internet? No Problem",
            subtitle:
            "Hops turns every phone into a relay, passing messages from device to device via Bluetooth.",
            icon: Icons.cell_tower,
            bgColor: colors.surface,
            avatarBg: colors.tertiaryContainer,
            avatarFg: colors.onTertiary,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildSquareBentoCard(
                  title: "Private & Secure",
                  detail: "Messages go device-to-device — nothing touches an internet server.",
                  icon: Icons.enhanced_encryption_outlined,
                  bgColor: colors.surface,
                  textColor: colors.onSurface,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildSquareBentoCard(
                  title: "Built for Students",
                  detail: "Offline chat and crowd checks, built for busy campus life.",
                  icon: Icons.group_outlined,
                  bgColor: colors.primaryContainer,
                  textColor: colors.onPrimaryContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _buildSquareBentoCard(
                  title: "Emergency Ready",
                  detail: "One long-press alerts everyone nearby, even offline.",
                  icon: Icons.warning_amber_rounded,
                  bgColor: colors.surface,
                  textColor: colors.onSurface,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildSquareBentoCard(
                  title: "Nearby & Now",
                  detail: "See who's nearby in real time on the Radar — no accounts needed.",
                  icon: Icons.radar,
                  bgColor: colors.tertiaryContainer,
                  textColor: colors.onTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
              ),
              onPressed: () => _pageController.animateToPage(1,
                  duration: const Duration(milliseconds: 500),
                  curve: Curves.easeInOutCubic),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("Next", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward, size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveFormStep() {
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: Icon(Icons.arrow_back, size: 16, color: colors.primary),
              label: Text("View info",
                  style: TextStyle(color: colors.primary, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis),
              onPressed: () => _pageController.animateToPage(0,
                  duration: const Duration(milliseconds: 400), curve: Curves.ease),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                _buildFormSwitcherToggle(),
                const SizedBox(height: 24),
                // Smooth crossfade+slide between the two forms instead of
                // an abrupt swap — a Row toggle that just teleports its
                // content used to feel like a glitch rather than a switch.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    final slide = Tween<Offset>(
                      begin: Offset(child.key == const ValueKey('join') ? -0.08 : 0.08, 0),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: Column(
                    key: ValueKey(isJoinMeshMode ? 'join' : 'signin'),
                    children: [
                      isJoinMeshMode ? _buildJoinMeshForm() : _buildSignInForm(),
                      _buildStatusMessage(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // widget.currentStatus was previously updated at every step of sign-up/
  // sign-in (root_gatekeeper.dart's authEngineStatus) but never actually
  // displayed anywhere in this screen — so a failure just silently
  // reverted the button with zero visible explanation. This is what
  // surfaces it, error or otherwise. Combined with _fieldError below for
  // this screen's own inline validation failures.
  Widget _buildStatusMessage() {
    final status = widget.currentStatus;
    final inline = _fieldError;
    if ((status.isEmpty || status == "System Ready") && inline == null) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final text = inline ?? (status.startsWith("Err:") ? status.substring(5) : status);
    final isError = inline != null || status.startsWith("Err:");
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isError ? Colors.red.withValues(alpha: 0.1) : colors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              size: 18,
              color: isError ? Colors.redAccent : colors.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  color: isError ? Colors.redAccent : colors.primary,
                  fontWeight: isError ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJoinMeshForm() {
    final colors = Theme.of(context).colorScheme;
    // AutofillGroup ties these fields together as one logical form, so the
    // platform's password manager (Google Password Manager, iOS Keychain,
    // etc.) offers to save the username/email + password as a set once
    // TextInput.finishAutofillContext() fires — see dispose() above — the
    // same way a browser offers to save a just-submitted signup form.
    return AutofillGroup(
      child: Column(
      key: const ValueKey('joinFields'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCapsuleInput(
          label: "USERNAME",
          bunnyHint: "What's your bunny's name?",
          requirement: "$kMinUsernameLength–$kMaxUsernameLength characters — letters, numbers, underscores",
          icon: Icons.alternate_email,
          controller: _usernameController,
          focusNode: _usernameFocus,
          autofillHints: const [AutofillHints.newUsername],
        ),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "EMAIL",
          bunnyHint: "Your carrot mail?",
          requirement: "You'll sign in with this — make sure it's real",
          icon: Icons.mail_outline,
          controller: _signupEmailController,
          focusNode: _signupEmailFocus,
          type: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "PASSWORD",
          bunnyHint: "Shh... your secret hop code",
          requirement: "8+ characters with upper & lowercase, a number, and a symbol",
          icon: Icons.lock_outline,
          controller: _passwordController,
          focusNode: _passwordFocus,
          obscure: _obscurePassword,
          isPasswordField: true,
          onPasswordToggle: () => setState(() => _obscurePassword = !_obscurePassword),
          belowChild: PasswordStrengthBar(password: _passwordController.text),
          autofillHints: const [AutofillHints.newPassword],
        ),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "CONFIRM PASSWORD",
          bunnyHint: "One more hop to be sure",
          requirement: "Must match the password above",
          icon: Icons.lock_outline,
          controller: _confirmPasswordController,
          focusNode: _confirmPasswordFocus,
          obscure: _obscureConfirmPassword,
          isPasswordField: true,
          onPasswordToggle: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
          autofillHints: const [AutofillHints.newPassword],
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.tertiaryContainer,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(100)),
            ),
            onPressed: _isLoading ? null : _submitJoinMesh,
            child: _isLoading
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text("Join Hops", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        )
      ],
      ),
    );
  }

  Future<void> _submitJoinMesh() async {
    setState(() => _fieldError = null);

    final usernameError = validateUsername(_usernameController.text);
    if (usernameError != null) {
      setState(() => _fieldError = usernameError);
      return;
    }
    // Institutional domain enforced here, not in validateEmail — see
    // validateAccountEmail's note on why forgot-password must stay
    // generic.
    final emailError = validateAccountEmail(_signupEmailController.text);
    if (emailError != null) {
      setState(() => _fieldError = emailError);
      return;
    }
    final passwordError = validatePassword(_passwordController.text);
    if (passwordError != null) {
      setState(() => _fieldError = passwordError);
      return;
    }
    if (_passwordController.text != _confirmPasswordController.text) {
      setState(() => _fieldError = "Passwords don't match.");
      return;
    }

    setState(() => _isLoading = true);
    try {
      await widget.onSignUpTrigger(
        email: _signupEmailController.text.trim(),
        password: _passwordController.text.trim(),
        username: _usernameController.text.trim(),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildSignInForm() {
    final colors = Theme.of(context).colorScheme;
    return AutofillGroup(
      child: Column(
      key: const ValueKey('signinFields'),
      children: [
        _buildCapsuleInput(
          label: "EMAIL",
          bunnyHint: "Your carrot mail?",
          requirement: "The email you signed up with",
          icon: Icons.mail_outline,
          controller: _signinEmailController,
          focusNode: _signinEmailFocus,
          type: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "PASSWORD",
          bunnyHint: "Your secret hop code",
          requirement: "The password you signed up with",
          icon: Icons.lock_outline,
          controller: _signinPasswordController,
          focusNode: _signinPasswordFocus,
          obscure: _obscurePassword,
          isPasswordField: true,
          onPasswordToggle: () => setState(() => _obscurePassword = !_obscurePassword),
          autofillHints: const [AutofillHints.password],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _isLoading
                ? null
                : () async {
                    final changed = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(builder: (_) => const ForgotPasswordScreen()),
                    );
                    if (changed == true && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Password changed — sign in with your new password.")),
                      );
                    }
                  },
            child: Text("Forgot password?", style: TextStyle(color: colors.primary, fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [colors.primary, colors.primaryContainer]),
              borderRadius: BorderRadius.circular(100),
            ),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent, foregroundColor: Colors.white),
              onPressed: _isLoading ? null : _submitSignIn,
              child: _isLoading
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text("Sign In", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        )
      ],
      ),
    );
  }

  Future<void> _submitSignIn() async {
    setState(() => _fieldError = null);
    if (_signinEmailController.text.trim().isEmpty || _signinPasswordController.text.isEmpty) {
      setState(() => _fieldError = "Please enter your email and password.");
      return;
    }
    setState(() => _isLoading = true);
    try {
      await widget.onSignInTrigger(
        email: _signinEmailController.text.trim(),
        password: _signinPasswordController.text.trim(),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // A label, an optional requirement line that only appears once the
  // field is focused (separating itself from the label the moment you tap
  // in, per the "Must be at least N characters" request), and a capsule
  // TextField whose hint text is likewise only shown while focused — every
  // field now looks as empty as the password field always has, until you
  // actually tap into it.
  Widget _buildCapsuleInput({
    required String label,
    required String bunnyHint,
    required String? requirement,
    required IconData icon,
    required TextEditingController controller,
    required FocusNode focusNode,
    bool obscure = false,
    bool isPasswordField = false,
    VoidCallback? onPasswordToggle,
    TextInputType type = TextInputType.text,
    Widget? belowChild,
    List<String>? autofillHints,
  }) {
    final colors = Theme.of(context).colorScheme;
    final hasFocus = focusNode.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16.0, bottom: 4.0),
          child: Text(
            label,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: colors.primary, letterSpacing: 1.2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: (requirement != null && hasFocus)
              ? Padding(
                  padding: const EdgeInsets.only(left: 16.0, bottom: 6.0),
                  child: Text(
                    requirement,
                    style: TextStyle(fontSize: 11, color: colors.onSurface.withValues(alpha: 0.55), fontStyle: FontStyle.italic),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscure,
          keyboardType: type,
          autofillHints: autofillHints,
          style: TextStyle(fontSize: 14, color: colors.onSurface),
          decoration: InputDecoration(
            // Only shown once focused — unfocused, every field now reads
            // as genuinely empty (student_handle/your@email.edu used to
            // sit there looking pre-filled, which is exactly what people
            // mistook them for) instead of a placeholder they thought
            // was real content.
            hintText: hasFocus ? bunnyHint : null,
            hintStyle: TextStyle(
              color: colors.onSurface.withValues(alpha: 0.35),
              fontStyle: FontStyle.italic,
              fontSize: 13,
            ),
            prefixIcon: Icon(icon, color: colors.primary.withValues(alpha: 0.6), size: 20),
            suffixIcon: isPasswordField
                ? IconButton(
              icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, color: colors.primary.withValues(alpha: 0.6), size: 20),
              onPressed: onPasswordToggle,
            )
                : (controller.text.isNotEmpty
                ? IconButton(
              icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
              onPressed: () => setState(() => controller.clear()),
            )
                : null),
            filled: true,
            fillColor: colors.surfaceContainerHighest,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(100), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          ),
        ),
        if (belowChild != null) belowChild,
      ],
    );
  }

  Widget _buildBentoInfoCard({required String title, required String subtitle, required IconData icon, required Color bgColor, required Color avatarBg, required Color avatarFg}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          CircleAvatar(backgroundColor: avatarBg, child: Icon(icon, color: avatarFg)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: colors.primary, fontSize: 14)),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: colors.onSurface.withValues(alpha: 0.6), height: 1.4),
                  // Was maxLines: 2 — at this card width the sentence
                  // reliably needed a 3rd line and was rendering as a
                  // truncated "…" instead of the actual full sentence.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSquareBentoCard({
    required String title,
    required String detail,
    required IconData icon,
    required Color bgColor,
    required Color textColor,
  }) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1.0,
      child: HopsFlipCard(
        front: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon, color: colors.primary, size: 28),
                  Icon(Icons.flip, size: 13, color: textColor.withValues(alpha: 0.35)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: textColor, height: 1.2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        back: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: colors.primary, size: 20),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: textColor, height: 1.2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Flexible(
                child: Text(
                  detail,
                  style: TextStyle(fontSize: 10.5, color: textColor.withValues(alpha: 0.8), height: 1.3),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormSwitcherToggle() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                isJoinMeshMode = false;
                _fieldError = null;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !isJoinMeshMode ? colors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Center(
                  child: Text(
                    "Sign In",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: !isJoinMeshMode ? Colors.white : colors.primary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                isJoinMeshMode = true;
                _fieldError = null;
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isJoinMeshMode ? colors.tertiaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Center(
                  child: Text(
                    "Join Hops",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: isJoinMeshMode ? Colors.white : colors.tertiaryContainer,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
