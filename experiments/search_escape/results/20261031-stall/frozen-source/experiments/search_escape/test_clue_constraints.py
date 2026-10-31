"""JSP-Oct26-Search-Escape; ©2026 ThomasB. Author: ThomasB."""
import unittest,collections
from clue_constraints import derive
from cpsat import geometry,distances

class ClueConstraintTests(unittest.TestCase):
    def test_original_high_clue_requires_large_region(self):
        clues=[-1]*121;clues[115]=0;clues[118]=77
        b=derive(dict(n=11,clues=clues))
        self.assertEqual(b['minimumLargestRegion'],26)
        self.assertEqual(b['witness']['steps'],3)

    def test_adjacent_difference_bounds_both_state_sizes(self):
        b=derive(dict(n=2,clues=[77,61,-1,-1]))
        self.assertEqual(b['adjacentSizeBounds'],[dict(cells=[0,1],minimumRegionSize=16)])

    def test_positive_clue_cannot_be_singleton_capital(self):
        b=derive(dict(n=2,clues=[1,3,0,-1]))
        self.assertEqual(b['singletonCapitalDisjunctions'],[dict(clueCell=0,candidateCells=[2])])

    def test_necessary_bounds_preserve_every_legal_two_by_two_partition(self):
        def partitions(prefix):
            if len(prefix)==4:yield prefix;return
            for v in range(max(prefix,default=-1)+2):yield from partitions(prefix+[v])
        checked=0
        for labels in partitions([]):
            parts=collections.defaultdict(list)
            for c,v in enumerate(labels):parts[v].append(c)
            if not all(geometry(cells,2)[0] for cells in parts.values()):continue
            d=distances(labels,2)
            if max(d)>=10**9:continue
            b=derive(dict(n=2,clues=d));checked+=1
            self.assertLessEqual(b['minimumLargestRegion'],max(map(len,parts.values())))
            for pair in b['adjacentSizeBounds']:
                self.assertTrue(all(len(parts[labels[c]])>=pair['minimumRegionSize'] for c in pair['cells']))
            for clause in b['singletonCapitalDisjunctions']:
                self.assertTrue(any(len(parts[labels[c]])==1 for c in clause['candidateCells']))
        self.assertGreater(checked,1)

if __name__=='__main__':unittest.main()
