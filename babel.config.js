// Metro does not expose shell variables to the device bundle. Inline this one
// when the config loads, so PASSKEY_KNOWN_RP_IDS is baked into the JS bundle.
function inlinePasskeyKnownRpIds({types: t}) {
	const value = process.env.PASSKEY_KNOWN_RP_IDS ?? '';
	return {
		name: 'inline-passkey-known-rp-ids',
		visitor: {
			MemberExpression(path) {
				const {node} = path;
				const env = node.object;
				if (
					node.computed ||
					node.property.type !== 'Identifier' ||
					node.property.name !== 'PASSKEY_KNOWN_RP_IDS' ||
					env.type !== 'MemberExpression' ||
					env.computed ||
					env.object.type !== 'Identifier' ||
					env.object.name !== 'process' ||
					env.property.type !== 'Identifier' ||
					env.property.name !== 'env'
				) {
					return;
				}
				path.replaceWith(t.stringLiteral(value));
			},
		},
	};
}

module.exports = {
	presets: ['module:@react-native/babel-preset'],
	plugins: [
		// React Compiler must run first so it can analyze components before
		// other transforms. react-native-worklets/plugin must remain last.
		'babel-plugin-react-compiler',
		inlinePasskeyKnownRpIds,
		'react-native-worklets/plugin',
	],
};
