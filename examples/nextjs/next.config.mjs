/** @type {import('next').NextConfig} */
const nextConfig = {
  // The SDK ships prebuilt dual ESM/CJS, but transpiling it keeps Next happy across app/pages boundaries.
  transpilePackages: ["@asseteragmbh/evm-contracts"],
};

export default nextConfig;
