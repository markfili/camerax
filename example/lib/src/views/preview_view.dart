import 'dart:io';

import 'package:flutter/material.dart';

import 'app_bar.dart';

class PreviewView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)!.settings.arguments as String;
    var image = File(args);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: ExampleAppBar(title: 'Preview'),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            image,
            fit: BoxFit.cover,
          ),
        ],
      ),
    );
  }
}
