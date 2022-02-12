import 'package:flutter/material.dart';

class ExampleAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;

  const ExampleAppBar({Key? key, required this.title}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 1,
      automaticallyImplyLeading: true,
      title: Text(title),
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight);
}
