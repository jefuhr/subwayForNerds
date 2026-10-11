export const PATH_ROUTES: Record<string, { label: string; color: string; stops: string[] }> = {
  'PATH-NWK-WTC': { label: 'NWK–WTC', color: '#D93A30', stops: ['NWK', 'HAR', 'JSQ', 'GRV', 'EXP', 'WTC'] },
  'PATH-HOB-WTC': { label: 'HOB–WTC', color: '#65C100', stops: ['HOB', 'NEW', 'EXP', 'WTC'] },
  'PATH-JSQ-33': { label: 'JSQ–33', color: '#FF9900', stops: ['JSQ', 'GRV', 'NEW', 'CHR', '09S', '14S', '23S', '33S'] },
  'PATH-HOB-33': { label: 'HOB–33', color: '#4D92FB', stops: ['HOB', 'NEW', 'CHR', '09S', '14S', '23S', '33S'] },
  'PATH-JSQ-33-HOB': { label: 'JSQ–33 via HOB', color: 'linear-gradient(135deg, #4D92FB 50%, #FF9900 50%)', stops: ['JSQ', 'GRV', 'NEW', 'HOB', 'CHR', '09S', '14S', '23S', '33S'] },
};
