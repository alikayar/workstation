"""Deterministic connected Python corpora; source and oracle share a declared model.

Imported by run.py. No benchmark, dependency installation or model call on import.
"""
import copy
import random
import shutil


def evaluator(domain, module):
    return f'evaluate_d{domain:02d}_m{module:03d}'


def module_file(domain, module):
    return f'domains/domain_{domain:02d}/module_{module:03d}.py'


def identity(domain, module):
    return module_file(domain, module), evaluator(domain, module)


def ancestors(edges, target, depth):
    """Expected incoming reachability of the declared calls, not extracted source."""
    found, frontier, seen = set(), {target}, {target}
    for _ in range(depth):
        parents = {source for source, targets in edges.items() if targets & frontier}
        frontier = parents - seen
        seen |= frontier
        found |= frontier
    return sorted({path for path, _ in found if path != target[0]})


def build(destination, base_fixture, base_spec, profile, seed):
    """Generate only into a new artifact directory. Return workload and dimensions."""
    if destination.exists():
        raise ValueError('Generated corpus destination must not already exist')
    if any(path.is_symlink() for path in base_fixture.rglob('*')):
        raise ValueError('Linked fixture paths are refused')
    shutil.copytree(base_fixture, destination)
    rng = random.Random(seed)
    domains, modules, fanout = (profile[key] for key in ('domains', 'modules_per_domain', 'fanout'))
    if not 2 <= domains <= 32 or not 16 <= modules <= 256 or not 1 <= fanout <= 6:
        raise ValueError('Unsupported corpus dimensions')
    edges, styles = {}, {}
    for domain in range(domains):
        for module in range(modules):
            targets = []
            if module:
                # Always connected locally. Additional edges vary with the seed.
                offsets = [1] + rng.sample(list(range(2, min(8, module) + 1)),
                                           min(fanout - 1, max(0, min(8, module) - 1)))
                targets.extend(identity(domain, module - offset) for offset in offsets)
            if domain and module % 8 == 0:
                targets.append(identity(domain - 1, module))
            source = identity(domain, module)
            edges[source] = set(targets)
            for target in targets:
                styles[source, target] = rng.choice(('direct', 'alias', 'namespace'))
    # A second half repeats the exact relation model with *direct* imports only.
    # This separates alias-resolution quality from scale/startup costs.
    direct_edges = {}
    direct_styles = {}
    for source, targets in list(edges.items()):
        path, name = source
        direct_source = ('direct_' + path, 'direct_' + name.removeprefix('evaluate_'))
        direct_targets = {('direct_' + target_path, 'direct_' + target_name.removeprefix('evaluate_')) for target_path, target_name in targets}
        direct_edges[direct_source] = direct_targets
        for target in direct_targets:
            direct_styles[direct_source, target] = 'direct'
    edges.update(direct_edges)
    styles.update(direct_styles)

    def write(name, text):
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    write('model.py', '''"""Shared typed data, no third-party dependency."""
from dataclasses import dataclass

@dataclass(frozen=True)
class Record:
    amount: int
    region: str = "local"
    active: bool = True
''')
    for package in ('domains', 'direct_domains'):
        write(package + '/__init__.py', '"""Generated service domains."""\n')
        for domain in range(domains):
            write(f'{package}/domain_{domain:02d}/__init__.py', '"""Generated bounded domain."""\n')

    import_styles = {'direct': 0, 'alias': 0, 'namespace': 0}
    for source, targets in sorted(edges.items()):
        path, name = source
        imports, calls = ['from model import Record'], []
        for number, target in enumerate(sorted(targets)):
            target_path, target_name = target
            module_name = target_path[:-3].replace('/', '.')
            style = styles[source, target]
            import_styles[style] += 1
            if style == 'namespace':
                imports.append(f'import {module_name} as peer_{number}')
                calls.append(f'peer_{number}.{target_name}(record)')
            else:
                alias = target_name if style == 'direct' else f'peer_evaluate_{number}'
                imports.append(f'from {module_name} import {target_name}' +
                               (f' as {alias}' if style == 'alias' else ''))
                calls.append(f'{alias}(record)')
        domain_number = int(path.split('/')[1].split('_')[1])
        body = '\n'.join(f'    value += {call}' for call in calls)
        write(path, '\n'.join(imports) + f'''

class Validator:
    """Repeated class/method names exercise scoped symbol identity."""

    def validate(self, record: Record) -> bool:
        return record.active and record.amount >= 0

    def normalize(self, record: Record) -> int:
        return max(record.amount, 0)


def {name}(record: Record) -> int:
    """Evaluate a typed service and its explicitly imported dependencies."""
    validator = Validator()
    if not validator.validate(record):
        return 0
    value = validator.normalize(record) + {domain_number}
{body}
    return value


def render_result(value: int) -> str:
    """A same-named helper in every module, deliberately outside the query set."""
    return f"result={{value}}"
''')

    entries = [identity(domain, modules - 1) for domain in range(domains)]
    entries += [('direct_' + path, 'direct_' + name.removeprefix('evaluate_')) for path, name in entries]
    lines, entry_calls = ['from model import Record'], []
    for number, (path, name) in enumerate(entries):
        direct = path.startswith('direct_domains/')
        binding = name if direct else f'entry_{number}'
        suffix = '' if direct else f' as {binding}'
        lines.append(f'from {path[:-3].replace("/", ".")} import {name}{suffix}')
        entry_calls.append(f'    result += {binding}(record)')
        import_styles['direct' if direct else 'alias'] += 1
    lines += ['', 'def run_all(record: Record) -> int:', '    result = 0']
    lines += entry_calls
    lines += ['    return result', '']
    write('generated_app.py', '\n'.join(lines))
    edges['generated_app.py', 'run_all'] = set(entries)

    spec = copy.deepcopy(base_spec)
    spec['fixture'] = 'generated-python'
    # Scored targets span early/middle/late domains; closures remain bounded.
    samples = [(0, modules - 8), (domains // 2, modules - 8), (domains - 1, modules // 2)]
    added_target = identity(domains // 2, modules - 8)
    new_node = ('generated_added.py', 'follow_added')
    changed_edges = {**edges, new_node: {added_target}}
    spec['changes'].append({
        'path': new_node[0], 'symbol': new_node[1],
        'content': f'from model import Record\nfrom {added_target[0][:-3].replace("/", ".")} import {added_target[1]} as selected_service\n\ndef follow_added(record: Record) -> int:\n    return selected_service(record)\n',
    })
    queries = []
    for position, (domain, module) in enumerate(samples):
        for direct in (False, True):
            path, name = identity(domain, module)
            if direct:
                path, name = 'direct_' + path, 'direct_' + name.removeprefix('evaluate_')
            prefix = f'generated-{position}-' + ('direct' if direct else 'mixed')
            queries += [
                {'id': prefix + '-definition', 'operation': 'definitions', 'symbol': name,
                 'expected_files': [path]},
                {'id': prefix + '-references', 'operation': 'references', 'symbol': name, 'file': path,
                 'expected_files': ancestors(edges, (path, name), 1),
                 'after_change_files': ancestors(changed_edges, (path, name), 1)},
                {'id': prefix + '-chain', 'operation': 'ancestors', 'symbol': name, 'file': path,
                 'max_depth': 6 if position == 2 else 3,
                 'expected_files': ancestors(edges, (path, name), 6 if position == 2 else 3),
                 'after_change_files': ancestors(changed_edges, (path, name), 6 if position == 2 else 3)},
            ]
    # Textual distractors mention actual targets but contain no corresponding calls.
    for position, target in enumerate(samples):
        name = evaluator(*target)
        write(f'notes/generated_{position}.py', f'"""Discussion of {name}, not executable usage."""\nEXAMPLE = "{name}(record)"\n')
    spec['cases'].extend(queries)
    files = sorted(path for path in destination.rglob('*') if path.is_file())
    return spec, {
        'generator_schema': 2, 'seed': seed, **profile,
        'service_modules': domains * modules * 2,
        'source_files': sum(path.suffix == '.py' for path in files),
        'source_lines': sum(len(path.read_text().splitlines()) for path in files),
        'source_bytes': sum(path.stat().st_size for path in files),
        'declared_service_call_edges': sum(len(targets) for targets in edges.values()),
        'import_styles': import_styles, 'cases': len(spec['cases']),
        'topology': 'paired direct/mixed-import DAGs; local fanout, domain bridges, common typed model and shared entrypoint',
    }
