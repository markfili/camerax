import 'package:flutter/material.dart';

class HomeView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CameraX'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(40.0),
          child: Text(
            'Use the:\n- camera button to take picture\n- qr code button to scan',
            style: TextStyle(fontSize: 20.0),
          ),
        ),
      ),
      bottomNavigationBar: BottomAppBar(
        shape: CircularNotchedRectangle(),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              onPressed: () => Navigator.of(context).pushNamed('capture'),
              icon: Icon(
                Icons.camera,
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pushNamed('analyze'),
              icon: Icon(
                Icons.qr_code,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
