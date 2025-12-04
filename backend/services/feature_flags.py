"""
Feature flags for gradual rollout.
"""
import os
import random
from typing import Optional


class FeatureFlags:
    """Manage feature flags with gradual rollout."""
    
    def __init__(self):
        self.agent_query_enabled = os.getenv('USE_AGENT_QUERY', 'false').lower() == 'true'
        self.agent_query_percentage = float(os.getenv('USE_AGENT_QUERY_PERCENTAGE', '0'))
        self.agent_query_user_whitelist = [
            uid.strip() for uid in os.getenv('USE_AGENT_QUERY_WHITELIST', '').split(',')
            if uid.strip()
        ]
    
    def should_use_agent_query(self, user_id: Optional[str] = None) -> bool:
        """
        Determine if agent query should be used.
        
        Args:
            user_id: Optional user identifier for whitelist
        
        Returns:
            bool: True if agent should be used
        """
        # Check if globally enabled
        if not self.agent_query_enabled:
            return False
        
        # Check whitelist
        if user_id and user_id in self.agent_query_user_whitelist:
            return True
        
        # Check percentage rollout
        if self.agent_query_percentage > 0:
            return random.random() * 100 < self.agent_query_percentage
        
        return False


# Global instance
feature_flags = FeatureFlags()

