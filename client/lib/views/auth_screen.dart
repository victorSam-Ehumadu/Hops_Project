import 'package:flutter/material.dart';

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

class _AuthScreenState extends State<AuthScreen> {
  final PageController _pageController = PageController();
  int _currentStep = 0;
  bool isJoinMeshMode = true;

  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;   // new

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(() => setState(() {}));
    _emailController.addListener(() => setState(() {}));
    _passwordController.addListener(() => setState(() {}));
    _confirmPasswordController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pageController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.6, -0.4),
            radius: 1.2,
            colors: [Color(0xFFd7fafa), Color(0xFFe2fffe)], // static safe fallback
          ),
        ),
        child: SafeArea(
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
        ),
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
          const SizedBox(height: 20),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text("Welcome to Hops",
                style: theme.textTheme.displayLarge?.copyWith(fontSize: 32)),
          ),
          const SizedBox(height: 8),
          const Text(
            "The offline campus network that lets you chat, share, and stay safe — no Wi‑Fi or data needed.",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 14),
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
                  icon: Icons.enhanced_encryption_outlined,
                  bgColor: colors.surface,
                  textColor: colors.onSurface,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildSquareBentoCard(
                  title: "Built for Students",
                  icon: Icons.group_outlined,
                  bgColor: colors.primaryContainer,
                  textColor: colors.onPrimaryContainer,
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
              color: Colors.white.withOpacity(0.7),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              children: [
                _buildFormSwitcherToggle(),
                const SizedBox(height: 24),
                isJoinMeshMode ? _buildJoinMeshForm() : _buildSignInForm(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinMeshForm() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCapsuleInput(label: "USERNAME", hint: "student_handle", icon: Icons.alternate_email, controller: _usernameController),
        const SizedBox(height: 16),
        _buildCapsuleInput(label: "EMAIL", hint: "your@email.edu", icon: Icons.mail_outline, controller: _emailController, type: TextInputType.emailAddress),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "PASSWORD",
          hint: "",
          icon: Icons.lock_outline,
          controller: _passwordController,
          obscure: _obscurePassword,
          isPasswordField: true,
          onPasswordToggle: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "CONFIRM PASSWORD",
          hint: "",
          icon: Icons.lock_outline,
          controller: _confirmPasswordController,
          obscure: _obscureConfirmPassword,
          isPasswordField: true,
          onPasswordToggle: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
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
            onPressed: _isLoading ? null : () async {
              if (_usernameController.text.isEmpty || _emailController.text.isEmpty || _passwordController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please fill in all registration fields!")));
                return;
              }
              if (_passwordController.text == _confirmPasswordController.text) {
                setState(() => _isLoading = true);
                try {
                  await widget.onSignUpTrigger(
                    email: _emailController.text.trim(),
                    password: _passwordController.text.trim(),
                    username: _usernameController.text.trim(),
                  );
                } finally {
                  setState(() => _isLoading = false);
                }
              } else {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Passwords do not match!")));
              }
            },
            child: _isLoading
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text("Join Mesh", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        )
      ],
    );
  }

  Widget _buildSignInForm() {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        _buildCapsuleInput(label: "EMAIL OR USERNAME", hint: "your@email.edu or handle", icon: Icons.person_outline, controller: _emailController),
        const SizedBox(height: 16),
        _buildCapsuleInput(
          label: "PASSWORD",
          hint: "",
          icon: Icons.lock_outline,
          controller: _passwordController,
          obscure: _obscurePassword,
          isPasswordField: true,
          onPasswordToggle: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
        const SizedBox(height: 24),
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
              onPressed: _isLoading ? null : () async {
                if (_emailController.text.isEmpty || _passwordController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please supply authentication metrics!")));
                  return;
                }
                setState(() => _isLoading = true);
                try {
                  await widget.onSignInTrigger(
                    email: _emailController.text.trim(),
                    password: _passwordController.text.trim(),
                  );
                } finally {
                  setState(() => _isLoading = false);
                }
              },
              child: _isLoading
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text("Sign In", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        )
      ],
    );
  }

  // ... rest of the methods (_buildCapsuleInput, _buildBentoInfoCard, etc.) remain unchanged
  Widget _buildCapsuleInput({
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController controller,
    bool obscure = false,
    bool isPasswordField = false,
    VoidCallback? onPasswordToggle,
    TextInputType type = TextInputType.text,
  }) {
    final colors = Theme.of(context).colorScheme;
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
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: type,
          style: TextStyle(fontSize: 14, color: colors.onSurface),
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, color: colors.primary.withOpacity(0.6), size: 20),
            suffixIcon: isPasswordField
                ? IconButton(
              icon: Icon(obscure ? Icons.visibility_off : Icons.visibility, color: colors.primary.withOpacity(0.6), size: 20),
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
                  style: const TextStyle(fontSize: 12, color: Colors.black54, height: 1.4),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSquareBentoCard({required String title, required IconData icon, required Color bgColor, required Color textColor}) {
    final colors = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 1.0,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Icon(icon, color: colors.primary, size: 28),
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
    );
  }

  Widget _buildFormSwitcherToggle() {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: colors.surface, borderRadius: BorderRadius.circular(100)),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => isJoinMeshMode = false),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !isJoinMeshMode ? colors.surfaceContainerHighest : Colors.transparent,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: const Center(
                    child: Text("Login",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        overflow: TextOverflow.ellipsis)),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => isJoinMeshMode = true),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isJoinMeshMode ? colors.tertiaryContainer : Colors.transparent,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Center(
                    child: Text("Join Hops",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13,
                            color: isJoinMeshMode ? Colors.white : colors.tertiaryContainer),
                        overflow: TextOverflow.ellipsis)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}