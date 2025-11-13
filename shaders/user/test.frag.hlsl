float4 main(float2 screen_pos : TEXCOORD) : SV_Target {
	const float3 color = float3(abs(screen_pos * 2 - 1), 0);
	return float4(color, 1);
}
