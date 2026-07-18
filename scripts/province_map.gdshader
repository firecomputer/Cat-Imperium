shader_type canvas_item;
render_mode unshaded;

uniform vec4 province_color : source_color = vec4(0.36, 0.36, 0.36, 1.0);
uniform vec4 selected_province_color : source_color = vec4(0.72, 0.72, 0.72, 1.0);
uniform vec4 country_border_color : source_color = vec4(0.035, 0.045, 0.065, 1.0);
uniform vec4 front_line_color : source_color = vec4(1.0, 0.30, 0.12, 1.0);
uniform vec4 selected_source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform bool has_selection = false;
uniform sampler2D province_id_texture : filter_nearest, repeat_disable;
uniform sampler2D political_palette : source_color, filter_nearest, repeat_disable;
uniform sampler2D front_palette : filter_nearest, repeat_disable;

const uint PROVINCE_COLOR_INVERSE = 9121617u;
const uint PROVINCE_PALETTE_SIZE = 128u;


uint province_id_from_source(vec4 source) {
	uvec3 rgb = uvec3(round(source.rgb * 255.0));
	uint packed = (rgb.r << 16u) | (rgb.g << 8u) | rgb.b;
	return (packed * PROVINCE_COLOR_INVERSE) & 16777215u;
}


vec4 province_palette_color(uint province_id) {
	ivec2 palette_pixel = ivec2(
		int(province_id % PROVINCE_PALETTE_SIZE),
		int(province_id / PROVINCE_PALETTE_SIZE)
	);
	return texelFetch(political_palette, palette_pixel, 0);
}


float province_front_marker(uint province_id) {
	ivec2 palette_pixel = ivec2(
		int(province_id % PROVINCE_PALETTE_SIZE),
		int(province_id / PROVINCE_PALETTE_SIZE)
	);
	return texelFetch(front_palette, palette_pixel, 0).r;
}


ivec2 wrapped_pixel(ivec2 pixel, ivec2 texture_size) {
	if (pixel.x < 0) {
		pixel.x += texture_size.x;
	} else if (pixel.x >= texture_size.x) {
		pixel.x -= texture_size.x;
	}
	pixel.y = clamp(pixel.y, 0, texture_size.y - 1);
	return pixel;
}


vec2 boundary_flags(
	ivec2 neighbor_pixel,
	ivec2 texture_size,
	vec3 political_color,
	float current_front
) {
	neighbor_pixel = wrapped_pixel(neighbor_pixel, texture_size);
	uint neighbor_id = province_id_from_source(texelFetch(province_id_texture, neighbor_pixel, 0));
	if (neighbor_id == 0u) {
		return vec2(1.0, 0.0);
	}
	vec4 neighbor_color = province_palette_color(neighbor_id);
	if (distance(neighbor_color.rgb, political_color) < 0.0005) {
		return vec2(0.0);
	}
	return vec2(
		1.0,
		current_front > 0.5 && province_front_marker(neighbor_id) > 0.5 ? 1.0 : 0.0
	);
}

void fragment() {
	ivec2 texture_size = textureSize(province_id_texture, 0);
	ivec2 pixel = ivec2(clamp(floor(UV * vec2(texture_size)), vec2(0.0), vec2(texture_size - ivec2(1))));
	vec4 source = texelFetch(province_id_texture, pixel, 0);
	uint province_id = province_id_from_source(source);
	bool is_water = province_id == 0u;
	bool is_selected = has_selection && all(lessThan(abs(source.rgb - selected_source_color.rgb), vec3(0.00001)));
	if (is_water) {
		COLOR = vec4(0.0, 0.0, 0.0, 1.0);
	} else {
		vec4 political_color = province_palette_color(province_id);
		float current_front = province_front_marker(province_id);
		vec2 flags = vec2(0.0);
		flags = max(flags, boundary_flags(pixel + ivec2(1, 0), texture_size, political_color.rgb, current_front));
		flags = max(flags, boundary_flags(pixel + ivec2(-1, 0), texture_size, political_color.rgb, current_front));
		flags = max(flags, boundary_flags(pixel + ivec2(0, 1), texture_size, political_color.rgb, current_front));
		flags = max(flags, boundary_flags(pixel + ivec2(0, -1), texture_size, political_color.rgb, current_front));
		if (flags.y > 0.5) {
			COLOR = front_line_color;
		} else if (is_selected) {
			COLOR = mix(vec4(political_color.rgb, 1.0), selected_province_color, 0.65);
		} else if (flags.x > 0.5) {
			COLOR = mix(vec4(political_color.rgb, 1.0), country_border_color, 0.75);
		} else if (current_front > 0.5) {
			COLOR = mix(vec4(political_color.rgb, 1.0), front_line_color, 0.18);
		} else {
			COLOR = vec4(political_color.rgb, 1.0);
		}
	}
}
