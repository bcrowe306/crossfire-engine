package engine

/*
The layer a node draws on (`Node.layer`). A scene draws Layer1 first and Layer8 last (on top);
within a layer, nodes draw by `zIndex`, and in tree order among equal ones. Layers in `Scene.screenLayers`
ignore the camera.
*/
RenderLayer :: enum {
	Layer1,
	Layer2,
	Layer3,
	Layer4,
	Layer5,
	Layer6,
	Layer7,
	Layer8
}

// A set of layers. (Not used by the engine: physics bodies use u64 collision layers and masks)
CollisionLayers :: bit_set[RenderLayer]
