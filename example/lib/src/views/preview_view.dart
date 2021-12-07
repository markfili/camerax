import 'dart:io';

import 'package:flutter/material.dart';

class PreviewView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)!.settings.arguments as String;
    var image = File(args);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 1,
        automaticallyImplyLeading: true,
        title: Text('Preview'),
      ),
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
