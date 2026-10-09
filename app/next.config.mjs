/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@pairwise/config"],
  webpack: (config, { webpack }) => {
    // Optional peer deps of wallet SDKs that Pairwise never calls (pretty logging, x402 payments).
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.plugins.push(new webpack.IgnorePlugin({ resourceRegExp: /^@x402\// }));
    config.resolve.alias = { ...config.resolve.alias, "@react-native-async-storage/async-storage": false };
    return config;
  },
};
export default nextConfig;
