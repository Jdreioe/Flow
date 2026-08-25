mod azure;
mod backend;
mod google;
mod piper;
mod selection;
mod settings;
mod shortcuts;
mod system_speech;
mod updates;

use cstr::cstr;
use qmetaobject::prelude::*;

use backend::FlowBackend;

fn main() {
    backend::install_theme_icons();

    qml_register_type::<FlowBackend>(cstr!("Flow"), 1, 0, cstr!("FlowBackend"));

    let mut engine = QmlEngine::new();
    engine.load_data(include_str!("../qml/Main.qml").into());
    engine.exec();
}
