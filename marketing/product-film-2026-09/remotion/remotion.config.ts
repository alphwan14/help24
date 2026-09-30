import { Config } from '@remotion/cli/config';

// Frames are rendered losslessly and encoded once, so UI text stays crisp.
Config.setVideoImageFormat('png');
Config.setCodec('h264');
Config.setCrf(15);
Config.setPixelFormat('yuv420p');
Config.setOverwriteOutput(true);
