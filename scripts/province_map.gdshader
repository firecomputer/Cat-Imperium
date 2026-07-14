shader_type canvas_item;
render_mode unshaded;

uniform vec4 province_color : source_color = vec4(0.36, 0.36, 0.36, 1.0);
uniform vec4 selected_province_color : source_color = vec4(0.72, 0.72, 0.72, 1.0);
uniform vec4 selected_source_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform bool has_selection = false;

void fragment() {
	ivec2 texture_size = textureSize(TEXTURE, 0);
	ivec2 pixel = ivec2(clamp(floor(UV * vec2(texture_size)), vec2(0.0), vec2(texture_size - ivec2(1))));
	vec4 source = texelFetch(TEXTURE, pixel, 0);
	bool is_water = all(lessThan(source.rgb, vec3(0.000001)));
	bool is_selected = has_selection && all(lessThan(abs(source.rgb - selected_source_color.rgb), vec3(0.00001)));
	if (is_water) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else if (is_selected) {
		COLOR = selected_province_color;
	} else {
		COLOR = province_color;
	}
}
