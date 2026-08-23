#![windows_subsystem = "windows"]

mod azure;
mod backend;
mod google;
mod selection;
mod settings;
mod shortcuts;
mod system_speech;

use cpp::cpp;
use cstr::cstr;
use qmetaobject::prelude::*;

cpp! {{
    #include <QtCore/QtGlobal>
    #include <QtCore/QByteArray>
    #include <QtGui/QCursor>
}}

use backend::FlowBackend;

fn main() {
    // Fusion supports control customization and keeps a consistent look
    // across Windows versions, closer to the macOS presentation. Qt reads
    // the environment through the CRT on Windows, so go through qputenv.
    cpp!(unsafe [] {
        qputenv("QT_QUICK_CONTROLS_STYLE", QByteArray("Fusion"));
        qputenv("QT_FORCE_STDERR_LOGGING", QByteArray("1"));
    });

    qml_register_type::<FlowBackend>(cstr!("Flow"), 1, 0, cstr!("FlowBackend"));

    let mut engine = QmlEngine::new();
    engine.load_data(include_str!("../qml/Main.qml").into());
    engine.exec();
}
