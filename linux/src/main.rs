mod azure;
mod backend;
mod google;
mod selection;
mod settings;
mod shortcuts;
mod system_speech;

use cstr::cstr;
use qmetaobject::prelude::*;

use backend::FlowBackend;

fn main() {
    qml_register_type::<FlowBackend>(cstr!("Flow"), 1, 0, cstr!("FlowBackend"));

    let mut engine = QmlEngine::new();
    engine.load_data(include_str!("../qml/Main.qml").into());
    engine.exec();
}
